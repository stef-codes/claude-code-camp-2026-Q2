module Boukensha
  module Tasks
    class Base
      DEFAULT_MAX_ITERATIONS = 25
      DEFAULT_MAX_OUTPUT_TOKENS = 1024

      def self.task_name
        raise NotImplementedError, "#{self} must define .task_name"
      end

      def self.provider(settings)
        fetch(settings, :provider) || raise(ArgumentError, "tasks.#{task_name}.provider is required in settings.yaml")
      end

      def self.model(settings)
        fetch(settings, :model) || raise(ArgumentError, "tasks.#{task_name}.model is required in settings.yaml")
      end

      def self.prompt_override?(settings, prompt = :system)
        node = fetch(settings, :prompt_override)
        return false unless node.is_a?(Hash)

        (node[prompt.to_s] || node[prompt.to_sym]) == true
      end

      # The last prompt this task resolved, and where it came from. Read by the
      # agent to stamp `langfuse.observation.prompt.name/version` on the
      # generation span — which is what makes a regression attributable to a
      # prompt version instead of merely visible.
      #
      # Class-level state, matching the rest of this class: prompts resolve once
      # per task per process, and a task class IS the per-task singleton here.
      def self.last_prompt_source = @last_prompt_source

      # Resolution order: Langfuse (if a registry is supplied and has this
      # prompt) → the user's override file → the prompt shipped on disk.
      #
      # Langfuse goes FIRST because that is the whole point — editing a prompt
      # there has to beat the copy in the repo, or "roll back without a
      # redeploy" is not true. It cannot go first safely without the registry
      # returning nil on every failure, which is why that class treats a
      # timeout, a 404 and a missing credential identically.
      def self.prompt(settings, name = :system, user_prompts_dir: nil, default_prompts_dir: nil,
                      registry: nil)
        @last_prompt_source = nil

        if registry && (remote = registry.fetch(langfuse_prompt_name(name)))
          @last_prompt_source = remote
          return remote.text
        end

        if prompt_override?(settings, name) && (text = read_user_prompt(name, user_prompts_dir: user_prompts_dir))
          return text
        end

        read_default_prompt(name, default_prompts_dir: default_prompts_dir)
      end

      # `boukensha-player-system`, `boukensha-explorer-system`. Namespaced
      # because a Langfuse project is shared across whatever else the team runs,
      # and "system" would be a careless thing to claim.
      def self.langfuse_prompt_name(prompt_name = :system)
        "boukensha-#{task_name}-#{prompt_name}"
      end

      def self.system_prompt(settings, user_prompts_dir: nil, default_prompts_dir: nil, registry: nil)
        prompt(settings, :system, user_prompts_dir: user_prompts_dir,
                                  default_prompts_dir: default_prompts_dir, registry: registry)
      end

      def self.max_iterations(settings)
        integer_setting(settings, :max_iterations, DEFAULT_MAX_ITERATIONS)
      end

      def self.max_output_tokens(settings)
        integer_setting(settings, :max_output_tokens, DEFAULT_MAX_OUTPUT_TOKENS)
      end

      class << self
        private

        def fetch(settings, key)
          return nil unless settings.is_a?(Hash)

          settings[key.to_s] || settings[key.to_sym]
        end

        def integer_setting(settings, key, default)
          value = fetch(settings, key)
          return default if value.nil?

          Integer(value)
        end

        def read_user_prompt(prompt_name, user_prompts_dir: nil)
          return nil unless user_prompts_dir

          read_file(File.join(user_prompts_dir, task_name, "#{prompt_name}.md"))
        end

        def read_default_prompt(prompt_name, default_prompts_dir: nil)
          return nil unless default_prompts_dir

          # Per-task default first (`prompts/explorer/system.md`), then the
          # shared player fallback (`prompts/system.md`).
          read_file(File.join(default_prompts_dir, task_name, "#{prompt_name}.md")) ||
            read_file(File.join(default_prompts_dir, "#{prompt_name}.md"))
        end

        def read_file(path)
          File.exist?(path) ? File.read(path).strip : nil
        end
      end
    end
  end
end
