# encoding: utf-8
module SceneryRmi::Entity::Helper
  module Locale
    module Base
      def view_resource(id, index = nil)
        index ||= controller_name
        resource = I18n.t("#{index.singularize}.views.#{id}", :raise => true) rescue nil
        resource || I18n.t("views.#{id}", :raise => true) rescue id.to_s.humanize
      end

      def view_action(id, index = nil)
        index ||= controller_name
        resource = I18n.t("#{index.singularize}.actions.#{id}", :raise => true) rescue nil
        resource || I18n.t("activerecord.actions.#{id}", :raise => true) rescue id.to_s.humanize
      end

      def view_message(id, index = nil)
        index ||= controller_name
        resource = I18n.t("#{index.singularize}.messages.#{id}", :raise => true) rescue nil
        resource || I18n.t("activerecord.messages.#{id}", :raise => true) rescue id.to_s.humanize
      end
    end

    def self.included(model)
      model.send(:include, Base)
      model.send(:extend, Base)
    end
  end
end