#encoding: utf-8
module SceneryRmi::Entity::Helper
  module EntityAccessor
    def assign_entity(entity)
      @__jrmi_entity = entity
    end

    def entity
      @__jrmi_entity
    end
  end
end