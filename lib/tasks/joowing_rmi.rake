# encoding: utf-8

namespace :joowing do
  namespace :api do

    @buffer = StringIO.new

    # output a line (support formats)
    def output(form, *args)
      if args.length == 0
        puts form
      else
        puts format(form, *args)
      end
    end # end output

    # dig out all name, backends of a module definition(includes it's sub constants)
    def names_and_backends(module_definition)
      names, backends = [], []
      names << module_definition.name
      backends << module_definition.backend if module_definition.backend
      module_definition.children.each do |ns|
        names << ns.name
        if ns.is_a? JoowingRmi::Definition::ModuleDefinition
          n,b = names_and_backends(ns)
          names.concat n
          backends.concat b
        else
          backends << ns.backend if ns.backend
        end
      end
      names.uniq!
      backends.uniq!
      [names, backends]
    end

    def show_description(subject)
      ENV['desc'] != 'false' and !subject.description.blank?
    end

    # output attributes of a class definition
    def output_attrs(definition, indent)
      judge_pk = if definition.primary_key
                   lambda do |attr|
                     definition.primary_key.intern == attr.name.intern
                   end
                 else
                   lambda { |attr| false }
                 end
      definition.attributes.sort! do |a, b|
        ra = judge_pk.call(a)
        rb = judge_pk.call(b)
        if ra
          -1
        elsif rb
          1
        else
          0
        end
      end
      output '  ' * indent + '[Attributes]:'
      indent += 1
      definition.attributes.each do |attr|
        pk = judge_pk.call(attr)
        output '%s%s', '  ' * indent, attr.to_s(pk)
      end
      output '  ' * indent + 'nothing' if definition.attributes.blank?

    end # output_attrs

    # output actions of a class definition
    def output_actions(definition, indent)
      output '  ' * indent + '[Actions]:'
      indent_space = '  ' * (indent + 1)
      definition.actions.each do |action|
        output '%s%s', indent_space, action.description if show_description(action)
        output '%s%s', indent_space, action.to_s(definition.prefix_path)
      end
      output '  ' * indent + 'nothing' if definition.actions.empty?
    end

    def not_meet(challenge, filter, leaf = false)
      return false if filter.blank?
      if leaf and challenge.include?('.')
        index = challenge.index('.')
        c = challenge[index+1 .. -1]
      else
        c = challenge
      end
      # filter 有2种，一种是 include, 一种是 exclude(以!开头)
      if /^!(?<reject>.*)/ =~ filter
        c.include? reject
      else
        !(c.include? filter)
      end
    end

    def not_meets(values, filter)
      return false if filter.blank?
      # filter 有2种，一种是 include, 一种是 exclude(以!开头)
      if /^!(?<reject>.*)/ =~ filter
        values.all? { |v| v.to_s.include?(reject) }
      else
        !values.any? { |v| v.to_s.include?(filter) }
      end
    end

    def desc_filter(m, c, backend, show_attr, show_action)
      filter = []
      filter << "module filter `#{m}`" unless m.blank?
      filter << "class filter `#{c}`" unless c.blank?
      filter << "backend filter `#{backend}`" unless backend.blank?
      filter << 'hide attributes' unless show_attr
      filter << 'hide actions' unless show_action
      if filter.blank?
        'without any filter'
      else
        'with ' + filter.join(' and ')
      end
    end

    desc 'Export API,Env: module|class|backend|attr|action|desc'
    task :dump do
      require 'joowing_rmi_syntax'
      # 根据module名称过滤
      m = ENV['module'] || ''
      # 根据class 名称过滤
      c = ENV['class'] || ''
      # 根据后台名称过滤
      backend = ENV['backend'] || ''
      # 是否显示属性
      show_attr = ENV['attr'] != 'false'
      # 是否显示动作
      show_action = ENV['action'] != 'false'
      filter = desc_filter(m, c, backend, show_attr, show_action)
      output 'Export Joowing API %s', filter
      JoowingRmi.joowing_platform_spec.update('joowing_rmi' => {redis: {host: '127.0.0.1', port: 6379}})
      JoowingRmi.initialize_rmi
      current_module_name = nil
      definitions = JoowingRmi::Manager.application.definitions
      keys = definitions.keys
      keys.sort!
      keys.each do |key|
        definition = definitions[key]
        count = key.to_s.count '.'
        indent_space = '  ' * count
        if definition.is_a? JoowingRmi::Definition::ModuleDefinition
          current_module_name = key
          next if not_meet(key, m)
          names, backends = names_and_backends(definition)
          next if not_meets(backends, backend)
          next if not_meets(names, c)
          output ''
          output '%s%s', indent_space, definition.description if show_description(definition)
          output '%s%s', indent_space, definition
        else
          next if not_meet(current_module_name.to_s, m)
          next if not_meet(definition.backend.to_s, backend)
          next if not_meet(key, c, true)
          output ''
          output '%s%s', indent_space, definition.description if show_description(definition)
          output '%s%s', indent_space, definition
          output_attrs(definition, count + 1) if show_attr
          output_actions(definition, count + 1) if show_action
        end # if definition is module
      end # module definition
    end # task :dump
  end # namespace :api
end # namespace :joowing
