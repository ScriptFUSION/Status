# frozen_string_literal: true

require 'emoji'
require 'octokit'

Jekyll::Hooks.register :pages, :pre_render do
  # @type [Jekyll::Page] page
  |page, payload|

  IndexController.index_action(payload) if page.url == '/'
end

# Provides an action to supply data to the index page.
module IndexController
  private

  GITHUB_RAW = 'application/vnd.github.raw'

  @client = Octokit::Client.new access_token: ENV['GITHUB_TOKEN']

  module_function

  # @param [Jekyll::Drops::UnifiedPayloadDrop] payload
  def index_action(payload)
    payload.page['github'] = @github ||= download_github_data
  end

  def download_github_data
    @client.organizations('bilge').map do |organization|
      puts "\nOrganization: #{organization.login}"

      organization
        .rels[:repos].get.data
        .select { |repository| repository.language == 'PHP' }
        .sort! do |a, b|
          (b.stargazers_count <=> a.stargazers_count).nonzero? ||
            b.pushed_at <=> a.pushed_at
        end.map! do |repository|
          puts "|- Repository: #{repository.name} "\
            "★#{repository.stargazers_count}"

          if repository.pushed_at < Time.now - 47335389 # 1.5 years
            puts "   ✗ Unmaintained. Last pushed on #{repository.pushed_at}."
            next
          end

          next if (readme = download_readme_references repository).nil?
          next if (composer = download_composer_json repository).nil?

          resource2hash(repository).merge!\
            'composer' => composer,
            'readme' => readme,
            'emoji' => parse_emojis(repository.description),
            'top_contributor' =>
              resource2hash(repository.rels[:contributors].get.data.first)
        end.reject(&:nil?)
    end.reject(&:empty?)
  end

  def download_composer_json(repository)
    JSON.parse download_file(repository, file = 'composer.json')
  rescue Octokit::NotFound
    puts %(   ✗ "#{file}" not found.)
  end

  def download_readme_references(repository)
    parse_markdown_references(
      @client.readme(repository.full_name, accept: GITHUB_RAW)
    ).each_with_object({}) do |item, hash|
      hash[item[0]] = {
        'url' => item[1],
        'title' => item[3]
      }
    end
  rescue Octokit::NotFound
    puts '   ✗ Readme not found.'
  end

  # @param [String] markdown
  def parse_markdown_references(markdown)
    markdown.scan(/
      ^ {,3}\[(?<id>.+?)\]:
      [[:blank:]]+(?<url>.+?)
      (?:[[:blank:]]+(?<q>[("'])(?<title>.+)\k<q>)?$
    /x)
  end

  # @param [String] text
  def parse_emojis(text)
    text.gsub(/:([\w+-]+):/).reduce('') do |mojis|
      mojis + Emoji.find_by_alias(Regexp.last_match(1))&.raw.to_s
    end
  end

  def download_file(repository, file)
    repository.rels[:contents].get(
      uri: { path: file },
      headers: { accept: GITHUB_RAW }
    ).data
  end

  # Converts the specified resources to a hash with string keys.
  # Liquid doesn't support symbol keys because it's garbage (#82).
  def resource2hash(resources)
    JSON.parse resources.to_h.to_json
  end
end
