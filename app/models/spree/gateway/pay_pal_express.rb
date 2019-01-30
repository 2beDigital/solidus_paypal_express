require 'paypal-sdk-merchant'
module Spree
  class Gateway::PayPalExpress < Gateway
    preference :use_new_layout, :boolean, default: true
    preference :login, :string
    preference :password, :string
    preference :signature, :string
    preference :server, :string, default: 'sandbox'
    preference :solution, :string, default: 'Mark'
    preference :landing_page, :string, default: 'Billing'
    preference :logourl, :string, default: ''

    def supports?(source)
      true
    end

    def provider_class
      ::PayPal::SDK::Merchant::API
    end

    def provider
      ::PayPal::SDK.configure(
        mode: preferred_server.present? ? preferred_server : "sandbox",
        username: preferred_login,
        password: preferred_password,
        signature: preferred_signature)
      provider_class.new
    end

    def auto_capture?
      #false
      true
    end

    def method_type
      'paypal'
    end

		def purchase(amount, express_checkout, gateway_options={})
			pp_details_request = provider.build_get_express_checkout_details(
			{
				Token: express_checkout.token
			}
			)
			pp_details_response = provider.get_express_checkout_details(pp_details_request)

			pp_request = provider.build_do_express_checkout_payment(
			{
				DoExpressCheckoutPaymentRequestDetails: {
					PaymentAction: "Sale",
					Token: express_checkout.token,
					PayerID: express_checkout.payer_id,
					PaymentDetails: pp_details_response.get_express_checkout_details_response_details.PaymentDetails
				}
			}
			)

			pp_response = provider.do_express_checkout_payment(pp_request)
			if pp_response.success?
				# We need to store the transaction id for the future.
				# This is mainly so we can use it later on to refund the payment if the user wishes.
				transaction_id = pp_response.do_express_checkout_payment_response_details.payment_info.first.transaction_id
				express_checkout.update_column(:transaction_id, transaction_id)
				# This is rather hackish, required for payment/processing handle_response code.
				Class.new do
					def success?; true; end
					def authorization; nil; end
				end.new
			else
				class << pp_response
					def to_s
						errors.map(&:long_message).join(" ")
					end
				end
				pp_response
			end
		end
		
    # amount :: float
    # express_checkout :: Spree::PaypalExpressCheckout
    # gateway_options :: hash
    def authorize(amount, express_checkout, gateway_options={})
      response =
        do_authorize(express_checkout.token, express_checkout.payer_id)

      # TODO don't do this, use authorization instead
      # this is a hold over from old code.
      # I don't think this actually even used by anything?
      express_checkout.update transaction_id: response.authorization

      response
    end

    # https://developer.paypal.com/docs/classic/api/merchant/DoCapture_API_Operation_NVP/
    # for more information
    def capture(amount_cents, authorization, currency:, **_options)
      do_capture(amount_cents, authorization, currency)
    end

		def refund(payment, amount)
			refund_type = payment.amount == amount.to_f ? "Full" : "Partial"
			refund_transaction = provider.build_refund_transaction(
				{ TransactionID: payment.source.transaction_id,
					RefundType: refund_type,
					Amount: {
						currencyID: payment.currency,
						value: amount },
					RefundSource: "any" })
			refund_transaction_response = provider.refund_transaction(refund_transaction)
			if refund_transaction_response.success?
				payment.source.update_attributes(
					{ refunded_at: Time.now,
						refund_transaction_id: refund_transaction_response.RefundTransactionID,
						state: "refunded",
						refund_type: refund_type
					})

				payment.class.create!(
					order: payment.order,
					source: payment,
					payment_method: payment.payment_method,
					amount: amount.to_f.abs * -1,
					response_code: refund_transaction_response.RefundTransactionID,
					state: 'completed'
				)
			end
			refund_transaction_response
		end
		 
    def credit(credit_cents, transaction_id, originator:, **_options)
      payment = originator.payment
      amount = credit_cents / 100.0

      refund_type = payment.amount == amount.to_f ? "Full" : "Partial"

      refund_transaction = provider.build_refund_transaction(
        { TransactionID: payment.source.transaction_id,
          RefundType: refund_type,
          Amount: {
            currencyID: payment.currency,
            value: amount },
          RefundSource: "any" })

      refund_transaction_response = provider.refund_transaction(refund_transaction)

      if refund_transaction_response.success?
        payment.source.update_attributes(
          { refunded_at: Time.now,
            refund_transaction_id: refund_transaction_response.RefundTransactionID,
            state: "refunded",
            refund_type: refund_type
        })
      end

      build_response(
        refund_transaction_response,
        refund_transaction_response.refund_transaction_id)
    end

    def server_domain
      self.preferred_server == "live" ?  "" : "sandbox."
    end

    def express_checkout_url(pp_response, extra_params={})
      params = {
        token: pp_response.Token
      }.merge(extra_params)

      if self.preferred_use_new_layout
        "https://www.#{server_domain}paypal.com/checkoutnow/2?"
      else
        "https://www.#{server_domain}paypal.com/cgi-bin/webscr?" +
          "cmd=_express-checkout&force_sa=true&"
      end +
      URI.encode_www_form(params)
    end

    def do_authorize(token, payer_id)
      response =
        self.
        provider.
        do_express_checkout_payment(
          checkout_payment_params(token, payer_id))

      build_response(response, authorization_transaction_id(response))
    end

    def do_capture(amount_cents, authorization, currency)
      response = provider.
        do_capture(
          provider.build_do_capture(
            amount: amount_cents / 100.0,
            authorization_id: authorization,
            complete_type: "Complete",
            currencycode: options[:currency]))

      build_response(response, capture_transaction_id(response))
    end

    def capture_transaction_id(response)
      response.do_capture_response_details.payment_info.transaction_id
    end

    # response ::
    #   PayPal::SDK::Merchant::DataTypes::DoExpressCheckoutPaymentResponseType
    def authorization_transaction_id(response)
      response.
        do_express_checkout_payment_response_details.
        payment_info.
        first.
        transaction_id
    end

    def build_response(response, transaction_id)
      ActiveMerchant::Billing::Response.new(
        response.success?,
        JSON.pretty_generate(response.to_hash),
        response.to_hash,
        authorization: transaction_id,
        test: sandbox?)
    end

    def payment_details(token)
      self.
        provider.
        get_express_checkout_details(
          checkout_details_params(token)).
        get_express_checkout_details_response_details.
        PaymentDetails
    end

    def checkout_payment_params(token, payer_id)
      self.
        provider.
        build_do_express_checkout_payment(
          build_checkout_payment_params(
            token,
            payer_id,
            payment_details(token)))
    end

    def checkout_details_params(token)
      self.
        provider.
        build_get_express_checkout_details(Token: token)
    end

    def build_checkout_payment_params(token, payer_id, payment_details)
      {
        DoExpressCheckoutPaymentRequestDetails: {
          PaymentAction: "Authorization",
          Token: token,
          PayerID: payer_id,
          PaymentDetails: payment_details
        }
      }
    end

    def sandbox?
      self.preferred_server == "sandbox"
    end
  end
end
