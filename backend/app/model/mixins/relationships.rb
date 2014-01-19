# A relationship is a one-to-one/one-to-many/many-to-many link between two
# records, where the link can have properties of its own.
#
# Each relationship generates a dynamic model class that represents the
# relationship and stores its properties in the database.  This code takes care
# of managing those relationship instances.  It:
#
#   * Generates classes in response to a 'define_relationship' definition
#
#   * Creates relationship instances for incoming JSON records (and linking up
#     the related objects
#
#   * Turns those relationships back into JSON when sequel_to_json is called
#
# Some bits of terminology used here:
#
#   * Referents -- the objects that an instance of a relationship refers to.
#     For example, if the relationship is "linked agent", the two referents will
#     be agent records.
#
#     Note that a relationship can refer to two objects of the same type.  This
#     leads to some awkwardness when trying to distinguish between the two.  As
#     a result, there's a common pattern of using "other_referent_than(obj)" to
#     mean "the referred record that isn't this one".
#
#   * Reference columns -- In the DB, each relationship is a row in a table.
#     The row contains columns for the relationship's properties, plus several
#     "reference columns".  These columns are foreign key references to records
#     in other tables.
#
#     Relationships between records of the same type create some awkwardness
#     here too, since links between two resource records (for example) require
#     two foreign key columns like 'resource_id_0' and 'resource_id_1'.  Now to
#     answer the question "Which resources involve the resource whose ID is 5?"
#     we need to check in both reference columns.
#
#     So, you'll see the "reference_columns_for(someclass)" helper used here.
#     This returns a list of the columns that might contain references to a
#     given record type.
#

# We'll create a concrete instance of this class for each defined relationship.
AbstractRelationship = Class.new(Sequel::Model) do

  # Create a relationship instance between two objects with a defined set of properties.
  def self.relate(obj1, obj2, properties)
    columns = if obj1.class == obj2.class
      # If our two related objects are of the same type, we'll get back multiple
      # columns here anyway
      raise ReferenceError.new("Can't relate an object to itself") if obj1.id == obj2.id

      self.reference_columns_for(obj1.class)
    else
      [self.reference_columns_for(obj1.class).first, self.reference_columns_for(obj2.class).first]
    end

    if columns.include?(nil)
      raise ("One of the relationship columns for #{obj1} and #{obj2} couldn't be found." +
             "  (Have you created the '#{table_name}' table?)")
    end

    self.create(Hash[columns.zip([obj1.id, obj2.id])].merge(properties))
  end


  # Find any relationship instances that reference 'victims' and modify them to
  # refer to 'target' instead.
  def self.transfer(target, victims)
    target_columns = self.reference_columns_for(target.class)

    victims_by_model = victims.reject {|v| (v.class == target.class) && (v.id == target.id)}.group_by(&:class)

    victims_by_model.each do |victim_model, victims|

      unless participating_models.include?(victim_model)
        raise ReferenceError.new("This class doesn't belong to relationship #{self}: #{victim.class}")
      end

      victim_columns = self.reference_columns_for(victim_model)

      victim_columns.each do |victim_col|

        # Find any relationship where the current column contains a reference to
        # our victim
        self.filter(victim_col => victims.map(&:id)).each do |relationship|

          # Remove this relationship's reference to the victim
          relationship[victim_col] = nil

          # Now add a new reference to the target (which, if the victim and
          # target are of different types, might require updating a different
          # column to the one we just set to NULL)
          target_columns.each do |target_col|

            if relationship[target_col]
              # This column is already used to reference the other record in our
              # relationship so we'll skip over it.  But while we're here, make
              # sure we're not about to create a circular relationship.

              if relationship[target_col] == target.id
                raise "Transfer would create a circular relationship!"
              end

            else
              # Found a free column.  Store our updated reference here.
              relationship[target_col] = target.id
              break
            end

          end

          relationship[:system_mtime] = Time.now
          relationship[:user_mtime] = Time.now

          relationship.save
        end
      end
    end
  end


  # Return the value of 'property' for any relationship involving 'obj'.
  def self.values_for_property(obj, property)
    result = []

    self.reference_columns_for(obj.class).each do |col|
      self.filter(col => obj.id).select(property).distinct.each do |relationship|
        result << relationship[property]
      end
    end

    result
  end


  def self.to_s
    "<#Relationship #{table_name}>"
  end

  # Methods for defining relationships
  def self.set_json_property(property); @json_property = property; end
  def self.json_property; @json_property; end


  def self.set_participating_models(models); @participating_models = models; end
  def self.participating_models; @participating_models or raise "No participating models set"; end


  def self.set_wants_array(val); @wants_array = val; end
  def self.wants_array?; @wants_array; end


  # Return a list of the relationship instances that refer to 'obj'.
  def self.find_by_participant(obj)
    # Find all columns in our relationship's table that are named after obj's table
    # These will contain references to instances of obj's class
    reference_columns = self.reference_columns_for(obj.class)
    matching_relationships = reference_columns.map {|col| self.filter(col => obj.id).all}.flatten(1)
    matching_relationships.sort_by {|relationship| relationship[:aspace_relationship_position]}
  end


  # Return a mapping of records and the relationships they participate in.
  # Input is a list like:
  #
  #  [rec1, rec2, ...]
  #
  # and the result is:
  #
  #  { rec1 => [relationship1, relationship2, ...],
  #    rec2 => [relationship3, ...],
  #    ...}
  #
  def self.find_by_participants(objs)
    result = {}

    return result if objs.empty?
    reference_columns = self.reference_columns_for(objs.first.class)

    objects_by_id = objs.group_by {|obj| obj.id}

    reference_columns.each do |col|
      self.filter(col => objects_by_id.keys).all.each do |relationship|
        obj = objects_by_id[relationship[col]].first
        result[obj] ||= []
        result[obj] << relationship
      end
    end

    result.each do |obj, relationships|
      relationships.sort_by! {|relationship| relationship[:aspace_relationship_position]}
    end

    result
  end


  # Return a list of the objects that are related to 'obj' via one of our
  # relationships
  def self.who_participates_with(obj)
    # Find all relationships involving obj
    relationships = self.find_by_participant(obj)

    relationships.map {|relationship|
      relationship.other_referent_than(obj)
    }
  end


  # A list of all DB columns that might contain a foreign key reference to a
  # record of type 'model'.
  def self.reference_columns_for(model)
    self.db_schema.keys.select { |column_name|
      column_name.to_s.downcase =~ /\A#{model.table_name.downcase}_id(_[0-9]+)?\z/
    }
  end


  # The properties for this relationship instance
  def properties
    self.values
  end


  # The record referred to by the current relationship that isn't 'obj'.
  def other_referent_than(obj)
    self.class.participating_models.each {|model|
      self.class.reference_columns_for(model).each {|column|
        if self[column] && (model != obj.class || self[column] != obj.id)
          return model.respond_to?(:any_repo) ? model.any_repo[self[column]] : model[self[column]]
        end
      }
    }

    nil
  end



  # The URI of the record referred to by the current relationship that isn't
  # 'obj'.
  def uri_for_other_referent_than(obj)
    self.class.participating_models.each {|model|
      self.class.reference_columns_for(model).each {|column|
        if self[column] && (model != obj.class || self[column] != obj.id)
          return model.my_jsonmodel.uri_for(self[column],
                                            :repo_id => RequestContext.get(:repo_id))
        end
      }
    }
  end

end


module Relationships

  def self.included(base)
    base.instance_eval do
      @relationships ||= {}
      @relationship_dependencies ||= {}
    end

    base.extend(ClassMethods)
  end


  def update_from_json(json, opts = {}, apply_nested_records = true)
    obj = super

    # Call this before and after the change since relationships might have been
    # removed and the previously linked objects might need reindexing.
    trigger_reindex_of_dependants
    self.class.apply_relationships(obj, json, opts)
    trigger_reindex_of_dependants

    obj
  end


  # True if any object links to this one under relationship 'name'
  def has_relationship?(name)
    self.class.relationship_dependencies[name].any? {|related_class|
      relationship_class = related_class.find_relationship(name, true)
      relationship_class && !relationship_class.find_by_participant(self).empty?
    }
  end


  # Store a list of the relationships that this object participates in.  Saves
  # looking up the DB for each one.
  attr_reader :cached_relationships
  def cache_relationships(relationship_defn, relationship_objects)
    @cached_relationships ||= {}
    @cached_relationships[relationship_defn] = relationship_objects
  end


  def trigger_reindex_of_dependants
    # Update the mtime of any record with a relationship to this one.  This
    # encourages the indexer to reindex records when, say, a subject is renamed.
    #
    # Once we have our list of unique models, inform each of them that our
    # instance has been updated (using a class method defined below).
    self.class.dependent_models.each do |model|
      model.touch_mtime_of_anyone_related_to(self)
    end
  end


  # Added to the mixed in class itself: return a list of the relationship
  # instances involving this object
  def my_relationships(name)
    self.class.find_relationship(name).find_by_participant(self)
  end


  # Return all object instances that are related to the current record by the
  # relationship named by 'name'.
  def related_records(name)
    relationship = self.class.find_relationship(name)
    records = relationship.who_participates_with(self)

    relationship.wants_array? ? records : records.first
  end


  # Find all relationships involving the records in 'victims' and rewrite them
  # to refer to us instead.
  def assimilate(victims)
    victims = victims.reject {|v| (v.class == self.class) && (v.id == self.id)}

    self.class.relationship_dependencies.each do |relationship, models|
      models.each do |model|
        model.transfer(relationship, self, victims)
      end
    end

    DB.attempt {
      victims.each(&:delete)
    }.and_if_constraint_fails {
      raise MergeRequestFailed.new("Can't complete merge: record still in use")
    }

    trigger_reindex_of_dependants
  end


  def transfer_to_repository(repository, transfer_group = [])
    # When a record is being transferred to another repository, any
    # relationships it has to records within the current repository must be
    # cleared.

    predicate = proc {|relationship|
      referent = relationship.other_referent_than(self)

      # Delete the relationship if we're repository-scoped and the referent is
      # in the old repository.  Don't worry about relationships to any of the
      # records that are going to be transferred along with us (listed in
      # transfer_group)
      (referent.class.model_scope == :repository &&
       referent.repo_id != repository.id &&
       !transfer_group.any?{|obj| obj.id == referent.id && obj.model == referent.model})
    }


    ([self.class] + self.class.dependent_models).each do |model|
      model.delete_existing_relationships(self, false, false, predicate)
    end

    super
  end


  module ClassMethods

    # Reset relationship definitions for the current class
    def clear_relationships
      @relationships = {}
    end


    def relationships
      @relationships.values
    end


    def relationship_dependencies
      @relationship_dependencies
    end


    def dependent_models
      @relationship_dependencies.values.flatten.uniq
    end


    def find_relationship(name, noerror = false)
      @relationships[name] or (noerror ? nil : raise("Couldn't find #{name} in #{@relationships.inspect}"))
    end

    # Define a new relationship.
    def define_relationship(opts)
      [:name, :contains_references_to_types].each do |p|
        opts[p] or raise "No #{p} given"
      end

      base = self

      ArchivesSpaceService.loaded_hook do
        # We hold off actually setting anything up until all models have been
        # loaded, since our relationships may need to reference a model that
        # hasn't been loaded yet.
        #
        # This is also why the :contains_references_to_types property is a proc
        # instead of a regular array--we don't want to blow up with a NameError
        # if the model hasn't been loaded yet.


        related_models = opts[:contains_references_to_types].call

        clz = Class.new(AbstractRelationship) do
          table = "#{opts[:name]}_rlshp".intern
          set_dataset(table)
          set_primary_key(:id)

          if !self.db.table_exists?(self.table_name)
            Log.warn("Table doesn't exist: #{self.table_name}")
          end

          set_participating_models([base, *related_models].uniq)
          set_json_property(opts[:json_property])
          set_wants_array(opts[:is_array].nil? || opts[:is_array])
        end

        opts[:class_callback].call(clz) if opts[:class_callback]

        @relationships[opts[:name]] = clz

        related_models.each do |model|
          model.include(Relationships)
          model.add_relationship_dependency(opts[:name], base)
        end
      end
    end


    # Delete all existing relationships for 'obj'.
    def delete_existing_relationships(obj, bump_lock_version_on_referent = false, force = false, predicate = nil)
      relationships.each do |relationship_defn|
        next if (!relationship_defn.json_property && !force)

        relationship_defn.find_by_participant(obj).each do |relationship|

          # If our predicate says to spare this relationship, leave it alone
          next if predicate && !predicate.call(relationship)

          # If we're deleting a relationship without replacing it, bump the lock
          # version on the referent object so it doesn't accidentally get
          # re-added.
          #
          # This will also encourage the indexer to pick up changes on deletion
          # (e.g. a subject gets deleted and we want to reindex the records that
          # reference it)
          if bump_lock_version_on_referent
            referent = relationship.other_referent_than(obj)
            DB.increase_lock_version_or_fail(referent) if referent
          end

          relationship.delete
        end
      end
    end


    # Create set of relationships for a given update
    def apply_relationships(obj, json, opts, new_record = false)
      delete_existing_relationships(obj) if !new_record

      @relationships.each do |relationship_name, relationship_defn|
        property_name = relationship_defn.json_property

        # If there's no property name, the relationship is just read-only
        next if !property_name

        # For each record reference in our JSON data
        ASUtils.as_array(json[property_name]).each_with_index do |reference, idx|
          record_type = parse_reference(reference['ref'], opts)

          referent_model = relationship_defn.participating_models.find {|model|
            model.my_jsonmodel.record_type == record_type[:type]
          } or raise "Couldn't find model for #{record_type[:type]}"

          referent = referent_model[record_type[:id]]

          if !referent
            raise ReferenceError.new("Can't relate to non-existent record: #{reference['ref']}")
          end

          # Create a new relationship instance linking us and them together, and
          # add the properties from the JSON request to the relationship
          properties = reference.clone.tap do |properties|
            properties.delete('ref')
          end

          properties[:aspace_relationship_position] = idx
          properties[:system_mtime] = Time.now
          properties[:user_mtime] = Time.now

          relationship_defn.relate(obj, referent, properties)

          # If this is a reciprocal relationship (defined on both participating
          # models), update the referent's lock version to ensure that a
          # concurrent update to that object won't clobber our changes.

          if referent_model.find_relationship(relationship_name, true) && !opts[:system_generated]
            DB.increase_lock_version_or_fail(referent)
          end
        end
      end
    end


    # Find all of the relationships involving 'objects' and tell each object to
    # cache its relationships.  This is an optimisation: avoids the need for one
    # SELECT for every relationship lookup by pulling back all relationships at
    # once.
    def eager_load_relationships(objects)
      relationships.each do |relationship_defn|
        # For each defined relationship
        relationships_map = relationship_defn.find_by_participants(objects)

        objects.each do |obj|
          obj.cache_relationships(relationship_defn, relationships_map[obj])
        end
      end
    end


    def create_from_json(json, opts = {})
      obj = super
      apply_relationships(obj, json, opts, true)
      obj
    end


    def sequel_to_jsonmodel(obj, opts = {})
      json = super

      return json if opts[:skip_relationships]

      relationships.each do |relationship_defn|
        property_name = relationship_defn.json_property

        # If we don't need this property in our return JSON, skip it.
        next unless property_name

        # For each defined relationship
        relationships = if obj.cached_relationships
                          # Use the eagerly fetched relationships if we have them
                          Array(obj.cached_relationships[relationship_defn])
                        else
                          relationship_defn.find_by_participant(obj)
                        end

        json[property_name] = relationships.map {|relationship|
          # Return the relationship properties, plus the URI reference of the
          # related object
          values = ASUtils.keys_as_strings(relationship.properties)
          values['ref'] = relationship.uri_for_other_referent_than(obj)

          values
        }

        if !relationship_defn.wants_array?
          json[property_name] = json[property_name].first
        end
      end

      json
    end


    # Find all instances of the referring class that have a relationship with 'obj'
    # Spans all defined relationships.
    def instances_relating_to(obj)
      relationships.map {|relationship_defn|
        relationship_defn.who_participates_with(obj)
      }.flatten
    end


    def add_relationship_dependency(relationship_name, clz)
      @relationship_dependencies[relationship_name] ||= []
      @relationship_dependencies[relationship_name] << clz
    end


    def transfer(relationship_name, target, victims)
      relationship = find_relationship(relationship_name)
      relationship.transfer(target, victims)
    end


    def prepare_for_deletion(dataset)
      dataset.select(:id).each do |obj|
        # Delete all the relationships created against this object
        delete_existing_relationships(obj, true, true)
        dependent_models.each do |model|
          model.delete_existing_relationships(obj, true, true) if model != self
        end
      end

      super
    end


    # This notifies the current model that an instance of a related model has
    # been changed.  We respond by finding any of our own instances that refer
    # to the updated instance and update their mtime.
    def touch_mtime_of_anyone_related_to(obj)
      now = Time.now

      relationships.map do |relationship_defn|
        models = relationship_defn.participating_models

        if models.include?(obj.class)
          their_ref_columns = relationship_defn.reference_columns_for(self)
          my_ref_columns = relationship_defn.reference_columns_for(self)
          their_ref_columns.each do |their_col|
            my_ref_columns.each do |my_col|
              ids_to_touch = relationship_defn.filter(their_col => obj.id).
                             select(my_col)
              self.filter(:id => ids_to_touch).
                   update(:system_mtime => now)
            end
          end
        end
      end
    end

  end
end
