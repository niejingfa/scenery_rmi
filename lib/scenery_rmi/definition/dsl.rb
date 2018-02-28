#encoding: utf-8
module SceneryRmi::Definition
  module DSL
    def self.included(main)
      if (main.superclass == BasicObject) &&
          main.respond_to?(:describe) &&
          !main.respond_to?(:describe_with_scenery) # not alias double times, to prevent multiple include
        # conflict with rspec in main object
        if defined?(RSpec::Core::DSL)
          RSpec::Core::DSL.module_eval do
            def describe_with_scenery(*args, &block)
              if block_given?
                # noinspection RubyResolve
                describe_without_scenery(*args, &block)
              else
                api_desc args.first
              end
            end
            alias_method_chain :describe, :scenery
          end
        end
      end
    end

    # Describe the next module/class/action
    # Duplicate descriptions are discarded.
    #
    # Example:
    #   describe 'The first module'
    #   define_module :test do |m|
    #     describe 'the first class'
    #     m.define_class :klass do |c|
    #       describe 'the first action'
    #       c.get 'tasks'
    #     end
    #   end
    #
    # 为了不与 rake/rspec 冲突
    def api_desc(description)
      SceneryRmi::Manager.last_description = description
    end

    # describe method for user
    def describe(description)
      api_desc(description)
    end

    def define_module(name, options = {}, &blk)
      namespaces = self.child_namespaces
      options.reverse_merge! defaults
      options[:description] = get_description
      definition = SceneryRmi::Definition::ModuleDefinition.new(namespaces, name, options).tap do |m|
        SceneryRmi::Manager.application.save(m)
        blk.call(m) if blk
      end
      add definition
    end

    def in_module(name, &blk)
      module_definition = SceneryRmi::Manager.application.get(name, self)
      blk.call(module_definition) if blk
    end

    def define_class(name, options = {}, &blk)
      namespaces = self.child_namespaces
      options.reverse_merge! defaults
      options[:description] = get_description
      definition = SceneryRmi::Definition::ClassDefinition.new(namespaces, name, options).tap do |c|
        SceneryRmi::Manager.application.save(c)
        blk.call(c) if blk
      end
      add definition
    end

    ################################
    # Inner methods
    ################################

    def get_description
      description = SceneryRmi::Manager.last_description
      SceneryRmi::Manager.last_description = nil
      description
    end

    def add(definition)
      self.children << definition if self.respond_to? :children
      definition
    end

    def child_namespaces
      self.namespaces + [self.name]
    rescue
      # maybe no these two methods
      []
    end

    def defaults
      hash = {}
      %w[backend primary_key prefix load_from_remote].each do |key|
        value = self.send(key) rescue next
        hash[key.intern] = value
      end
      hash
    end
  end
end