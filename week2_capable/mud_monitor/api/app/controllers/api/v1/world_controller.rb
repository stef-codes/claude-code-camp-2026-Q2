module Api
  module V1
    # The true world, and the agent's map drawn against it.
    #
    # Separate from KnowledgeController and polled separately (15s, against
    # knowledge's 3s) for two reasons. The world is static — it changes only when
    # someone regenerates the JSON — so it does not deserve the knowledge tab's
    # budget. And a missing or broken world dir must never be able to blank the
    # map: knowledge renders on its own, this decorates it.
    #
    # No SSE, same as knowledge: there is no cursor and nothing to tail.
    class WorldController < ApplicationController
      rescue_from ::Knowledge::Reader::SchemaMismatch, with: :render_schema_mismatch

      # GET /api/v1/world/overlay
      #
      # `limit: 1000` matches KnowledgeController::MAX_LIMIT. The overlay is a
      # decoration of the map page, so it covers exactly the rooms that page can
      # draw and no more.
      def overlay
        atlas = ::World::Atlas.for_dir(cfg.world_dir)

        payload = ::Knowledge::Reader.open(path: cfg.knowledge_db, live_window: cfg.live_window) do |reader|
          ::World::Overlay.new(atlas: atlas, rooms: reader.rooms(limit: MAX_ROOMS)).as_json
        end

        render json: payload
      end

      private

      MAX_ROOMS = 1000

      def cfg = profile_config

      def render_schema_mismatch(error)
        render json: { error: { code: "knowledge_schema_mismatch",
                                message: error.message,
                                schema_version: error.schema_version } },
               status: :service_unavailable
      end
    end
  end
end
