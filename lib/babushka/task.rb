module Babushka
  class Task
    include LogHelpers
    include PathHelpers
    include ShellHelpers

    attr_reader :opts, :caches, :persistent_log
    attr_accessor :reportable

    def initialize
      @opts = Base.cmdline.opts.dup
      @running = false
      @caching = false
    end

    def process dep_names, with_args
      raise "A task is already running." if running?
      @running = true
      cleanup_saved_vars # TODO: remove after August '13 or so.
      Base.in_thread { RunReporter.post_reports }
      dep_names.all? {|dep_name| process_dep(dep_name, with_args) }
    rescue SourceLoadError => e
      Babushka::Logging.log_exception(e)
    ensure
      @running = false
    end

    def process_dep dep_name, with_args
      Dep.find_or_suggest(dep_name) do |dep|
        log_dep(dep) {
          dep.with(task_args_for(dep, with_args)).process
        }.tap {|result|
          log_stderr "You can view #{opt(:debug) ? 'the' : 'a more detailed'} log at '#{log_path_for(dep)}'." unless result
          RunReporter.queue(dep, result, reportable)
          BugReporter.report(dep) if reportable
        }
      end
    end

    def cache &block
      was_caching, @caching, @caches = @caching, true, {}
      block.call
    ensure
      @caching = was_caching
    end

    def cached key, opts = {}, &block
      if !@caching
        block.call
      elsif @caches.has_key?(key)
        @caches[key].tap {|value|
          opts[:hit].call(value) if opts.has_key?(:hit)
        }
      else
        @caches[key] = block.call
      end
    end

    def task_info dep, result
      {
        :version => Base.ref,
        :run_at => Time.now,
        :system_info => Babushka.host.description,
        :dep_name => dep.name,
        :source_uri => dep.dep_source.uri,
        :result => result
      }
    end

    def opt name
      opts[name]
    end

    def running?
      @running
    end

    def callstack
      @callstack ||= []
    end

    def log_path_for dep
      log_prefix / dep.contextual_name
    end

    private

    def task_args_for dep, with_args
      with_args.keys.inject({}) {|hsh,k|
        # The string arg names are sanitized in the 'meet' cmdline handler.
        hsh[k.to_sym] = with_args[k]; hsh
      }.tap {|arg_hash|
        if (unexpected = arg_hash.keys - dep.params).any?
          log_warn "Ignoring unexpected argument#{'s' if unexpected.length > 1} #{unexpected.map(&:to_s).map(&:inspect).to_list}, which the dep '#{dep.name}' would reject."
          unexpected.each {|key| arg_hash.delete(key) }
        end
      }
    end

    def log_dep dep
      log_prefix.mkdir
      log_path_for(dep).open('w') {|f|
        f.sync = true
        @persistent_log = f

        # Note the current babushka & ruby versions at the top of the log.
        LogHelpers.debug(Base.runtime_info)

        yield
      }
    ensure
      @persistent_log = nil
    end

    def log_prefix
      LogPrefix.p
    end

    def cleanup_saved_vars
      VarsPrefix.p.rm if VarsPrefix.p.exists?
    end

  end
end
