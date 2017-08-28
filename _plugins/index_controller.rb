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

      download_repositories organization
    end.reject(&:empty?)
  end

  def download_repositories(organization)
    organization
      .rels[:repos].get.data
      .sort!(&method(:sort_repositories))
      .map!(&method(:decorate_repository))
      .reject(&:nil?)
  end

  def announce_repo(repository)
    return if @last_repo == repository

    puts "|- Repository: #{repository.name} ★#{repository.stargazers_count}"
    @last_repo = repository
  end

  def print_repo_error(repository, message)
    announce_repo repository

    puts '   ✗ ' + message
  end

  def sort_repositories(a, b)
    (b.stargazers_count <=> a.stargazers_count).nonzero? ||
      b.pushed_at <=> a.pushed_at
  end

  def filter_repository(repository)
    return false unless repository.language == 'PHP'

    return true unless repository.description =~ /(\[(?:OLD|DEPRECATED)\])/
    print_repo_error repository, "Tagged as: #{Regexp.last_match(1)}."
  end

  def decorate_repository(repository)
    return unless filter_repository repository
    return if (readme = download_readme_references repository).nil?
    return if (composer = download_composer_json repository).nil?

    announce_repo repository

    resource2hash(repository).merge!\
      'composer' => composer,
      'readme' => readme,
      'top_contributor' => download_top_contributor(repository),
      'emoji' => parse_emojis(repository.description)
  end

  def download_composer_json(repository)
    JSON.parse download_file(repository, file = 'composer.json')
  rescue Octokit::NotFound
    print_repo_error repository, %("#{file}" not found.)
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
    print_repo_error repository, 'Readme not found.'
  end

  def download_top_contributor(repository)
    resource2hash repository.rels[:contributors].get.data.first
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
