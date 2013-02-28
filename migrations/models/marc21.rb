ASpaceExport::model :marc21 do
  
  include JSONModel
    
  @repository_map = {
    :repo_code => :handle_repo_code,
  }
  
  @archival_object_map = {
    :title => :handle_title,
    :linked_agents => :handle_agents,
    :subjects => :handle_subjects,
    :extent => :handle_extents,
  }
  
  @resource_map = {
    :identifier => :handle_id,
    :notes => :handle_notes,
  }
  
  @@datafield = Class.new do
    
    attr_accessor :tag
    attr_accessor :ind1
    attr_accessor :ind2
    attr_accessor :subfields

    
    def initialize(*args)
      @tag, @ind1, @ind2 = *args
      @subfields = []
    end
    
    def with_sfs(*sfs)
      sfs.each {|sf| @subfields << @@subfield.new(*sf) }
      return self
    end
    
  end
  
  @@subfield = Class.new do
    
    attr_accessor :code
    attr_accessor :text
    
    def initialize(*args)
      @code, @text = *args
    end
    
  end
  
  def initialize
    @datafields = {}
  end
  
  def datafields
    @datafields.map {|k,v| v}
  end
  

  def self.from_aspace_object(obj)
  
    marc = self.new
    
    if obj.class.model_scope == :repository
      marc.apply_map(Repository.get_or_die(obj.repo_id), @repository_map)
    end
    
    marc
  end
    
  # 'archival object's in the abstract
  def self.from_archival_object(obj)
    
    marc = self.from_aspace_object(obj)
    
    marc.apply_map(obj, @archival_object_map)
    
    marc.apply_mapped_relationships(obj, @archival_object_map)
     
    marc
  end
    
  # subtypes of 'archival object':
  
  def self.from_resource(obj)
    marc = self.from_archival_object(obj)
    marc.apply_map(obj, @resource_map)
    
    marc
  end
  
  
  def df(*args)
    if @datafields.has_key?(args.to_s)
      @datafields[args.to_s]
    else
      @datafields[args.to_s] = @@datafield.new(*args)
      @datafields[args.to_s]
    end
  end
  
  def handle_id(jsonstr)
    df('852').with_sfs(['c', JSON.parse(jsonstr).join('--')])
  end
  
  def handle_title(title)
    Log.debug("TITLE #{title}")
    df('852').with_sfs(['b', title])
  end 
  
  def handle_repo_code(code)
    df('852').with_sfs(['a', "Repository: #{code}"])
  end
  
  def handle_subjects(subjects)
    subjects.each do |subject|
      json = subject[1].class.to_jsonmodel(subject[1])
      
      json.terms.each do |term|
        
        code =case term['term_type']
              when 'Uniform title' then '630'
              when 'Topical' then '650'
              when 'Geographic' then '651'
              when 'Genre / form' then '655'
              when 'Occupation' then '656'
              when 'Function' then '657'
              else
                '650' # ??????
              end
        
        df(code, nil, '7').with_sfs(['a', term['term']])
      end
    end
  end
  
  def handle_agents(linked_agents)
    linked_agents.each do |linked_agent|
      json = linked_agent[1].class.to_jsonmodel(linked_agent[1])

      role = linked_agent[0][:role]

      json.names.each do |name|
        case json.agent_type
        when 'agent_person'
          a = ['primary_name', 'rest_of_name'].map {|np| name[np] if name[np] }.join(', ')
          df('700', '1').with_sfs(['a', a], ['e', role])
          
        when 'agent_family'
          a = name['family_name']
          df('700', '3').with_sfs(['a', a], ['e', role])
        
        when 'agent_corporate_entity'
          a = name['primary_name']
          df('700', '2').with_sfs(['a', a], ['e', role])
        end
      end
        
    end
  end
  
  def handle_notes(notes_str)
    notes = ASUtils.json_parse(DB.deblob(notes_str) || "[]")
    
    notes.each do |note|

      knote = Proc.new{ |d,s| df(d).with_sfs([s, note['content']]) }

      case note['type']
      
      when 'Arrangement'
        knote.call('352','b')
      when 'General'
        knote.call('500','a')
      when 'Conditions Governing Access'
        knote.call('506','a')
      when 'Scope and Contents'
        knote.call('520','a')
      when 'Preferred Citation'
        knote.call('524','a')
      when 'Immediate Source of Acquisition'
        knote.call('541','a')
      when 'Related Archival Materials'
        knote.call('544','a')
      when 'Biographical / Historical'
        knote.call('545','a')
      when 'Other Finding Aids'
        knote.call('555','a')
      when 'Custodial History'
        knote.call('561','a')
      when 'Appraisal'
        knote.call('583','a')
      when 'Accruals'
        knote.call('584', 'a')
      end
    end 
  end
  
  def handle_extents(extents)
    extents.each do |ext|
      e = ext.number
      e << " (#{ext.portion})" if ext.portion
      e << " #{ext.extent_type}"
      df('300').with_sfs(['a', e])
    end
  end

      
  
end
