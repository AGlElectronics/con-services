# frozen_string_literal: true

# Development only. The standard deployment is DocuSeal Pro, which signs
# staff in through the same SSO as the other modules and embeds the builder
# with a Pro token. This file signs the local sandbox in as its first user
# so the HR forms page can frame the builder without a second login.
# Mounted by Compose when DEV_AUTO_SIGN_IN=true. Do not use it in production.

if ENV['DEV_AUTO_SIGN_IN'] == 'true'
  Rails.application.config.to_prepare do
    ApplicationController.class_eval do
      prepend_before_action :dev_auto_sign_in

      def dev_auto_sign_in
        return if signed_in?

        user = User.order(:id).first
        sign_in(user) if user
      end
    end
  end
end
