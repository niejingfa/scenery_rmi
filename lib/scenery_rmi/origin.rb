#encoding: utf-8

module SceneryRmi
  class Origin
    include Enumerable

    class JCollection < ::WillPaginate::Collection
      include SceneryRmi::Entity::ToListData
    end

    def initialize(rmi_klass)
      @rmi_klass = rmi_klass
      @loaded = false
      @data = []

      @model_options = {}
      @additional_options = {}
      @system_options = {}
      @context = {}
    end

    def context(c = {})
      @context.update(c)
      self
    end

    def query(opt = {})
      append_model_options(opt)
      self
    end

    def limit(size = 1)
      append_additional_option(limit: size)
      self
    end

    def path_params(params)
      symbolized_params = params
      if params.respond_to?(:symbolize_keys)
        symbolized_params = symbolized_params.symbolize_keys
      end

      @additional_options.update(symbolized_params)

      self
    end

    # one ending of origin
    def paginate(opt = {})
      append_additional_option(opt)
      @data = fetch_data unless @loaded
      @data
    end

    def sort(opt = {})
      merge_additional_option(:sort, opt)
      self
    end

    # 按照关键字搜索, 如果后端没有升级, 这个结果会无效
    # @param [String, [Array<String>]] keyword_value
    def keywords(keyword_value)
      append_additional_option(:keywords => keyword_value)
      self
    end

    def append_model_options(opt = {})
      @model_options.update(opt.symbolize_keys)
    end

    def merge_additional_option(name, opt = {})
      @additional_options[name.to_sym] ||= {}
      @additional_options[name.to_sym].update(opt)
    end

    def append_additional_option(opt = {})
      @additional_options.update(opt.symbolize_keys)
    end

    def append_system_options(opt = {})
      @system_options.update(opt.symbolize_keys)
    end

    def each
      @data = fetch_data unless @loaded
      @data.each { |d| yield(d) }
    end

    def method_missing(method_name, *args)
      if @data.respond_to? method_name
        @data.send(method_name, *args)
      else
        super(method_name, *args)
      end
    end

    def respond_to?(method_name)
      super.respond_to?(method_name) || @data.respond_to?(method_name)
    end

    protected
    # 与raw_fetch_data不同,会判断是否需要使用paginate来支援
    def fetch_data
      if @additional_options.has_key?(:page)
        total_entries = 0
        page = @additional_options[:page]
        per_page = @additional_options[:per_page] || 10
        JCollection.create(page, per_page) do |pager|
          data = begin
            @rmi_klass.get_by_raw(generate_raw_options) do |resp|
              total_entries = (resp['total_entries'] || 1).to_i
            end  
          rescue ActiveResource::ResourceNotFound
            # Swallowing ResourceNotFound exceptions and return nil - as per
            # ActiveRecord.
            nil
          end

          unless data.nil?
            pager.replace data
          end

          pager.total_entries = total_entries
        end
      else
        @rmi_klass.get_by_raw(generate_raw_options)
      end.tap { @loaded = true }
    end

    # 通过AR的接口,直接调用connection来查询所有的数据
    def raw_fetch_data
      @rmi_klass.get_by_raw(generate_raw_options)
    end

    def generate_raw_options
      opt =  @system_options.dup
      opt[:params] = @additional_options.dup.update(@rmi_klass.element_name => @model_options)

      unless @context.empty?
        opt[:params][:context] = @context
      end
      opt
    end


  end
end