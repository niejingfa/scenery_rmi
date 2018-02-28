#encoding: utf-8
module JoowingRmi
  class Entity < Grape::Entity
    module Helper
      require 'joowing_rmi/entity/helper/entity_accessor'
      require 'joowing_rmi/entity/helper/controller_helper'
    end

    include JoowingRmi::Entity::Helper::EntityAccessor
    include JoowingRmi::Entity::Helper::ControllerHelper
    include ActionView::Helpers::OutputSafetyHelper rescue nil
    include ActionView::Helpers::TagHelper rescue nil
    include ActionView::Helpers::CaptureHelper rescue nil

    class_attribute :__default_helpers
    self.__default_helpers = []

    class_attribute :__helpers
    self.__helpers = []

    module ToListData
      def to_list
        total = self.total_entries / self.per_page
        total += 1 if self.total_entries % self.per_page > 0


        { 
          total: total,
          records:  self.total_entries,
          rows: self,
          page: self.current_page 
        }
      end

      def to_ext_list
        {
            items: self,
            total: self.total_entries
        }
      end
    end

    def self.help(klass)
      if klass.is_a?(Module)
        self.__helpers << klass
        self.__helpers.uniq!
        self.__helpers
      elsif klass.is_a?(String)
        klass = klass.camelize.safe_constantize
        self.help(klass) if klass
      end

      
    end

    # 当使用paginate的时候, 
    def self.wrap_collection(collection, controller, ctx = {})
      WillPaginate::Collection.create(collection.current_page, collection.per_page) do |pager|
        pager.replace wrap_array(collection, controller, ctx)
        pager.total_entries = collection.total_entries
      end.tap do |array|
        array.singleton_class.send(:include, ToListData)
      end
    end

    # 为了能够正常使用
    def self.wrap_array(array_data, controller = nil, ctx = {})
      array_data.map do |data|
        wrap_data(data, controller, ctx)  
      end.tap do |array|
        array.singleton_class.send(:include, ToListData)
      end
    end

    def self.wrap_data(data, controller = nil, ctx = {})
      represent(data, ctx).tap do |entity|
        # entity.object.assign_entity(entity)
        entity.assign_controller(controller)
        entity.ctx = ctx
      end
    end

    attr_accessor :ctx

    def initialize(*args)
      super(*args)

      # self.class.__default_helpers.each do |mod|
      #   @object.singleton_class.send(:include, mod)
      # end

      # self.class.__helpers.each do |mod|
      #   @object.singleton_class.send(:include, mod)
      # end

      @ctx = {}
    end

    def object
      @object
    end

    # 需要使用content_tag的时候,它会去替换ActiveView下面的output_buffer,
    # 但是我们的Entity没有这个东西,于是hock它
    def with_output_buffer(buf = nil) #:nodoc:
      unless buf
        buf = ActionView::OutputBuffer.new
      end
      self.output_buffer = buf
      yield
      output_buffer
    end
  end
end