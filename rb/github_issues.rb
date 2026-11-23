# Alerts by GitHub issue: GitHub mails the repository's watchers (the owner) when an issue is
# opened or commented. One open issue per alert label, kept in sync with the current problem:
#   problem, no open issue      -> open one (mail)
#   problem changed             -> new body + a comment (mail)
#   same problem                -> nothing (no mail every hour)
#   no problem, issue open      -> comment + close (mail)
# "Same problem" = same `key` (e.g. the list of hut ids), stored in the body as an HTML comment,
# so that messages varying from run to run (timeouts...) don't send mails.
# Needs GITHUB_TOKEN (permission issues: write) and GITHUB_REPOSITORY, set in GitHub Actions;
# without them (locally), prints what it would do.

require "json"
require "net/http"
require "uri"

module GitHubIssues
  module_function

  API = "https://api.github.com"

  def marker(key) = "<!-- alert-key: #{key} -->"

  # body: Markdown of the current problem, or nil when everything is fine.
  def sync(label:, title:, body:, key: body)
    token, repo = ENV["GITHUB_TOKEN"], ENV["GITHUB_REPOSITORY"]
    unless token && !token.empty? && repo && !repo.empty?
      warn(body ? "[#{label}] problem (no GITHUB_TOKEN, no issue):\n#{body}" : "[#{label}] nothing to report")
      return :local
    end
    open = api(token, :get, "/repos/#{repo}/issues?state=open&labels=#{URI.encode_www_form_component(label)}&per_page=10")
           .find { |i| !i.key?("pull_request") }
    if body.nil?
      return :ok unless open
      api(token, :post, "/repos/#{repo}/issues/#{open['number']}/comments", { body: "Tout est rentré dans l'ordre : alerte close automatiquement." })
      api(token, :patch, "/repos/#{repo}/issues/#{open['number']}", { state: "closed", state_reason: "completed" })
      return :closed
    end
    full = "#{body}\n\n#{marker(key)}\n"
    if open.nil?
      api(token, :post, "/repos/#{repo}/issues", { title: title, body: full, labels: [label] })
      :opened
    elsif !open["body"].to_s.include?(marker(key))
      api(token, :patch, "/repos/#{repo}/issues/#{open['number']}", { body: full })
      api(token, :post, "/repos/#{repo}/issues/#{open['number']}/comments", { body: "La liste a changé :\n\n#{body}" })
      :updated
    else
      :unchanged
    end
  end

  def api(token, method, path, payload = nil)
    uri = URI("#{API}#{path}")
    req = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch }.fetch(method).new(uri)
    req["Authorization"] = "Bearer #{token}"
    req["Accept"] = "application/vnd.github+json"
    req["X-GitHub-Api-Version"] = "2022-11-28"
    if payload
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(payload)
    end
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 20, read_timeout: 30) { |h| h.request(req) }
    raise "GitHub API #{method.upcase} #{path}: HTTP #{res.code} #{res.body.to_s[0, 200]}" unless res.code.start_with?("2")
    res.body.to_s.empty? ? nil : JSON.parse(res.body)
  end
end
