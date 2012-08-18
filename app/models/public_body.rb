# == Schema Information
# Schema version: 95
#
# Table name: public_bodies
#
#  id                 :integer         not null, primary key
#  name               :text            not null
#  short_name         :text            not null
#  request_email      :text            not null
#  version            :integer         not null
#  last_edit_editor   :string(255)     not null
#  last_edit_comment  :text            not null
#  created_at         :datetime        not null
#  updated_at         :datetime        not null
#  url_name           :text            not null
#  home_page          :text            default(""), not null
#  notes              :text            default(""), not null
#  first_letter       :string(255)     not null
#  publication_scheme :text            default(""), not null
#

# models/public_body.rb:
# A public body, from which information can be requested.
#
# Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
# Email: francis@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: public_body.rb,v 1.160 2009-10-02 22:56:35 francis Exp $

class PublicBody < ActiveRecord::Base
    strip_attributes!

    validates_presence_of :name, :message => N_("Name can't be blank")
    validates_presence_of :url_name, :message => N_("URL name can't be blank")

    validates_uniqueness_of :short_name, :message => N_("Short name is already taken"), :if => Proc.new { |pb| pb.short_name != "" }
    validates_uniqueness_of :name, :message => N_("Name is already taken")

    has_many :info_requests, :order => 'created_at desc'
    has_many :track_things, :order => 'created_at desc'

    has_tag_string

    translates :name, :short_name, :request_email, :url_name, :notes, :first_letter, :publication_scheme

    # Convenience methods for creating/editing translations via forms
    def translation(locale)
        self.translations.find_by_locale(locale)
    end

    # XXX - Don't like repeating this!
    def calculate_cached_fields(t)
        t.first_letter = t.name.scan(/^./mu)[0].upcase unless t.name.nil? or t.name.empty?
        short_long_name = t.name
        short_long_name = t.short_name if t.short_name and !t.short_name.empty?
        t.url_name = MySociety::Format.simplify_url_part(short_long_name, 'body')
    end

    def translated_versions
        translations
    end

    def translated_versions=(translation_attrs)
        def skip?(attrs)
            valueless = attrs.inject({}) { |h, (k, v)| h[k] = v if v != '' and k != 'locale'; h } # because we want to fall back to alternative translations where there are empty values
            return valueless.length == 0
        end

        if translation_attrs.respond_to? :each_value    # Hash => updating
            translation_attrs.each_value do |attrs|
                next if skip?(attrs)
                t = translation(attrs[:locale]) || PublicBody::Translation.new
                t.attributes = attrs
                calculate_cached_fields(t)
                t.save!
            end
        else                                            # Array => creating
            translation_attrs.each do |attrs|
                next if skip?(attrs)
                new_translation = PublicBody::Translation.new(attrs)
                calculate_cached_fields(new_translation)
                translations << new_translation
            end
        end
    end

    # Make sure publication_scheme gets the correct default value.
    # (This would work automatically, were publication_scheme not a translated attribute)
    def after_initialize
      self.publication_scheme = "" if self.publication_scheme.nil?
    end

    # like find_by_url_name but also search historic url_name if none found
    def self.find_by_url_name_with_historic(name)
        locale = self.locale || I18n.locale
        PublicBody.with_locale(locale) do
            found = PublicBody.find(:all,
                                    :conditions => ["public_body_translations.url_name='#{name}'"],
                                    :joins => :translations,
                                    :readonly => false)
            # If many bodies are found (usually because the url_name is the same across
            # locales) return any of them
            return found.first if found.size >= 1

            # If none found, then search the history of short names
            old = PublicBody::Version.find_all_by_url_name(name)
            # Find unique public bodies in it
            old = old.map { |x| x.public_body_id }
            old = old.uniq
            # Maybe return the first one, so we show something relevant,
            # rather than throwing an error?
            raise "Two bodies with the same historical URL name: #{name}" if old.size > 1
            return unless old.size == 1
            # does acts_as_versioned provide a method that returns the current version?
            return PublicBody.find(old.first)
        end
    end

    # Set the first letter, which is used for faster queries
    before_save(:set_first_letter)
    def set_first_letter
        # we use a regex to ensure it works with utf-8/multi-byte
        self.first_letter = self.name.scan(/./mu)[0].upcase
    end

    def validate
        # Request_email can be blank, meaning we don't have details
        if self.is_requestable?
            unless MySociety::Validate.is_valid_email(self.request_email)
                errors.add(:request_email, "Request email doesn't look like a valid email address")
            end
        end
    end

    # If tagged "not_apply", then FOI/EIR no longer applies to authority at all
    def not_apply?
        return self.has_tag?('not_apply')
    end
    # If tagged "defunct", then the authority no longer exists at all
    def defunct?
        return self.has_tag?('defunct')
    end

    # Can an FOI (etc.) request be made to this body, and if not why not?
    def is_requestable?
        if self.defunct?
            return false
        end
        if self.not_apply?
            return false
        end
        if self.request_email.nil?
            return false
        end
        return !self.request_email.empty? && self.request_email != 'blank'
    end
    # Strict superset of is_requestable?
    def is_followupable?
        if self.request_email.nil?
            return false
        end
        return !self.request_email.empty? && self.request_email != 'blank'
    end
    # Also used as not_followable_reason
    def not_requestable_reason
        if self.defunct?
            return 'defunct'
        elsif self.not_apply?
            return 'not_apply'
        elsif self.request_email.nil? or self.request_email.empty? or self.request_email == 'blank'
            return 'bad_contact'
        else
            raise "requestable_failure_reason called with type that has no reason"
        end
    end

    acts_as_versioned
    self.non_versioned_columns << 'created_at' << 'updated_at' << 'first_letter'
    class Version
        attr_accessor :created_at

        def last_edit_comment_for_html_display
            text = self.last_edit_comment.strip
            text = CGI.escapeHTML(text)
            text = MySociety::Format.make_clickable(text)
            text = text.gsub(/\n/, '<br>')
            return text
        end
    end

    acts_as_xapian :texts => [ :name, :short_name, :notes ],
        :values => [
             [ :created_at_numeric, 1, "created_at", :number ] # for sorting
        ],
        :terms => [ [ :variety, 'V', "variety" ],
                [ :tag_array_for_search, 'U', "tag" ]
        ]
    def created_at_numeric
        # format it here as no datetime support in Xapian's value ranges
        return self.created_at.strftime("%Y%m%d%H%M%S")
    end
    def variety
        return "authority"
    end

    # if the URL name has changed, then all requested_from: queries
    # will break unless we update index for every event for every
    # request linked to it
    after_update :reindex_requested_from
    def reindex_requested_from
        if self.changes.include?('url_name')
            for info_request in self.info_requests
                for info_request_event in info_request.info_request_events
                    info_request_event.xapian_mark_needs_index
                end
            end
        end
    end

    # When name or short name is changed, also change the url name
    def short_name=(short_name)
        globalize.write(self.class.locale || I18n.locale, :short_name, short_name)
        self[:short_name] = short_name
        self.update_url_name
    end

    def name=(name)
        globalize.write(self.class.locale || I18n.locale, :name, name)
        self[:name] = name
        self.update_url_name
    end

    def update_url_name
        self.url_name = MySociety::Format.simplify_url_part(self.short_or_long_name, 'body')
    end

    # Return the short name if present, or else long name
    def short_or_long_name
        if self.short_name.nil? || self.short_name.empty?   # 'nil' can happen during construction
            self.name.nil? ? "" : self.name
        else
            self.short_name
        end
    end


    # Use tags to describe what type of thing this is
    def type_of_authority(html = false)
        types = []
        first = true
        for tag in self.tags
            if PublicBodyCategories::get().by_tag().include?(tag.name)
                desc = PublicBodyCategories::get().singular_by_tag()[tag.name]
                if first
                    # terrible that Ruby/Rails doesn't have an equivalent of ucfirst
                    # (capitalize shockingly converts later characters to lowercase)
                    desc = desc[0,1].capitalize + desc[1,desc.size]
                    first = false
                end
                if html
                    # XXX this should call proper route helpers, but is in model sigh
                    desc = '<a href="/body/list/' + tag.name + '">' + desc + '</a>'
                end
                types.push(desc)
            end
        end
        if types.size > 0
            ret = types[0, types.size - 1].join(", ")
            if types.size > 1
                ret = ret + " and "
            end
            ret = ret + types[-1]
            return ret
        else
            return _("A public authority")
        end
    end

    # Guess home page from the request email, or use explicit override, or nil
    # if not known.
    def calculated_home_page
        if home_page && !home_page.empty?
            home_page[URI::regexp(%w(http https))] ? home_page : "http://#{home_page}"
        elsif request_email_domain
            "http://www.#{request_email_domain}"
        end
    end

    # Are all requests to this body under the Environmental Information Regulations?
    def eir_only?
        return self.has_tag?('eir_only')
    end

    def law_only_short
        if self.eir_only?
            return "EIR"
        else
            return "FOI"
        end
    end

    # Schools are allowed more time in holidays, so we change some wordings
    def is_school?
        return self.has_tag?('school')
    end

    # The "internal admin" is a special body for internal use.
    def PublicBody.internal_admin_body
        PublicBody.with_locale(I18n.default_locale) do
            pb = PublicBody.find(:all, :conditions => {:url_name => "internal_admin_authority"}).first
            #pb = PublicBody.find_by_url_name("internal_admin_authority")
            if pb.nil?
                pb = PublicBody.new(
                 :name => 'Internal admin authority',
                 :short_name => "",
                 :request_email => MySociety::Config.get("CONTACT_EMAIL", 'contact@localhost'),
                 :home_page => "",
                 :notes => "",
                 :publication_scheme => "",
                 :last_edit_editor => "internal_admin",
                 :last_edit_comment => "Made by PublicBody.internal_admin_body"
                )
                pb.save!
            end
            return pb
        end
    end

    # Does this user have the power of FOI officer for this body?
    def is_foi_officer?(user)
        user_domain = user.email_domain
        our_domain = self.request_email_domain

        if user_domain.nil? or our_domain.nil?
            return false
        end

        return our_domain == user_domain
    end

    def foi_officer_domain_required
        return self.request_email_domain
    end

    # Domain name of the request email
    def request_email_domain
        return PublicBody.extract_domain_from_email(self.request_email)
    end

    # Return the domain part of an email address, canonicalised and with common
    # extra UK Government server name parts removed.
    def PublicBody.extract_domain_from_email(email)
        email =~ /@(.*)/
        if $1.nil?
            return nil
        end

        # take lower case
        ret = $1.downcase

        # remove special email domains for UK Government addresses
        ret.sub!(".gsi.", ".")
        ret.sub!(".x.", ".")
        ret.sub!(".pnn.", ".")

        return ret
    end

    def reverse_sorted_versions
        self.versions.sort { |a,b| b.version <=> a.version }
    end

    def sorted_versions
        self.versions.sort { |a,b| a.version <=> b.version }
    end

    def has_notes?
        return self.notes != ""
    end

    def notes_as_html
        self.notes
    end

    def notes_without_html
        # assume notes are reasonably behaved HTML, so just use simple regexp on this
        self.notes.nil? ? '' : self.notes.gsub(/<\/?[^>]*>/, "")
    end

    def json_for_api
        return {
            :id => self.id,
            :url_name => self.url_name,
            :name => self.name,
            :short_name => self.short_name,
            # :request_email  # we hide this behind a captcha, to stop people doing bulk requests easily
            :created_at => self.created_at,
            :updated_at => self.updated_at,
            # don't add the history as some edit comments contain sensitive information
            # :version, :last_edit_editor, :last_edit_comment
            :home_page => self.calculated_home_page,
            :notes => self.notes,
            :publication_scheme => self.publication_scheme,
            :tags => self.tag_array,
        }
    end

end


