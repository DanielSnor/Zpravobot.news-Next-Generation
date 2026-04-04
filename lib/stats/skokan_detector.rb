# frozen_string_literal: true

module Stats
  # Detects the "skokan týdne" (biggest weekly mover) for ZpravobotStats hitparáda.
  #
  # Returns BOTH types every week (activity + followers), not alternating.
  #
  # :activity  — largest relative increase in posts vs previous week
  #              MIN_POSTS_PREV filters out bots just starting up
  # :followers — largest absolute gain in followers vs previous snapshot
  #              Only available from week 2 onward (when snapshot exists)
  #
  # Pure class — no DB or HTTP dependencies.
  #
  class SkokanDetector
    # Minimum posts last week to qualify for activity skokan.
    # Prevents newly activated or reactivated bots from dominating.
    MIN_POSTS_PREV = 20

    # Detect both skokani for this week.
    # @param posts_per_account [Hash] { account_id => { this_week:, last_week: } }
    # @param previous_snapshot [Hash, nil] { account_id => { followers:, ... } }
    # @param mastodon_stats [Hash] { account_id => { followers:, statuses:, ... } }
    # @return [Hash] { activity: Hash|nil, followers: Hash|nil }
    def detect(posts_per_account, previous_snapshot, mastodon_stats)
      {
        activity:  detect_activity_skokan(posts_per_account),
        followers: detect_followers_skokan(mastodon_stats, previous_snapshot)
      }
    end

    private

    def detect_activity_skokan(posts_per_account)
      best     = nil
      best_pct = 0

      posts_per_account.each do |account_id, data|
        prev = data[:last_week].to_i
        curr = data[:this_week].to_i
        next if prev < MIN_POSTS_PREV
        next if curr <= prev

        pct = ((curr - prev).to_f / prev * 100).round
        next if pct <= best_pct

        best_pct = pct
        best = {
          type:         :activity,
          account:      account_id.to_s,
          this_week:    curr,
          last_week:    prev,
          relative_pct: pct,
          description:  "#{prev} → #{curr} postů (+#{pct}%)"
        }
      end

      best
    end

    def detect_followers_skokan(mastodon_stats, previous_snapshot)
      return nil unless previous_snapshot && !previous_snapshot.empty?

      best      = nil
      best_gain = 0

      mastodon_stats.each do |account_id, data|
        prev_data = previous_snapshot[account_id.to_s] ||
                    previous_snapshot[account_id.to_sym]
        next unless prev_data && !prev_data[:followers].nil?

        curr_followers = data[:followers].to_i
        prev_followers = prev_data[:followers].to_i
        gain = curr_followers - prev_followers
        next if gain <= 0
        next if gain <= best_gain

        pct = prev_followers > 0 ? ((gain.to_f / prev_followers) * 100).round : 0

        best_gain = gain
        best = {
          type:         :followers,
          account:      account_id.to_s,
          current:      curr_followers,
          previous:     prev_followers,
          gain:         gain,
          relative_pct: pct,
          description:  "#{prev_followers} → #{curr_followers} sledujících (+#{gain})"
        }
      end

      best
    end
  end
end
