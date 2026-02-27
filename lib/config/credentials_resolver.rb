# frozen_string_literal: true

module Config
  # Resolves Mastodon credentials for a source configuration
  #
  # Handles:
  # - Loading account credentials from mastodon_accounts.yml
  # - ENV override for tokens (ZBNW_MASTODON_TOKEN_{ACCOUNT_ID})
  # - Falling back to global mastodon instance
  class CredentialsResolver
    # Resolve and inject Mastodon credentials into merged config
    # @param merged [Hash] Merged configuration (will be mutated)
    # @param credentials_loader [#call] Callable that loads credentials by account_id
    # @param global_config [Hash] Global configuration (for instance fallback)
    # @return [Hash] The merged config with credentials injected
    def resolve(merged, credentials_loader, global_config)
      account_id = merged.dig(:target, :mastodon_account)
      return merged unless account_id

      creds = credentials_loader.call(account_id)

      # ENV override: token_env from config, or standard naming convention
      token_env_name = creds[:token_env] || "ZBNW_MASTODON_TOKEN_#{account_id.upcase}"
      env_token = ENV[token_env_name]

      merged[:target][:mastodon_token] = env_token && !env_token.empty? ? env_token : creds[:token]
      merged[:target][:mastodon_instance] = creds[:instance] || global_config.dig(:mastodon, :instance)

      merged
    end
  end
end
