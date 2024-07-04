# frozen_string_literal: true

require "mysql2"
require "time"
require "date"

require File.expand_path(File.dirname(__FILE__) + "/base.rb")

class ImportScripts::FLARUM < ImportScripts::Base
  #SET THE APPROPRIATE VALUES FOR YOUR MYSQL CONNECTION
  FLARUM_HOST ||= ENV["FLARUM_HOST"] || "localhost"
  FLARUM_DB ||= ENV["FLARUM_DB"] || "flarum"
  BATCH_SIZE ||= 1000
  FLARUM_USER ||= ENV["FLARUM_USER"] || "root"
  FLARUM_PW ||= ENV["FLARUM_PW"] || ""

  AVATAR_UPLOADS_DIR ||= "/var/discourse/shared/standalone/import/data/"

  def initialize
    super

    @client =
      Mysql2::Client.new(
        host: FLARUM_HOST,
        username: FLARUM_USER,
        password: FLARUM_PW,
        database: FLARUM_DB,
      )
  end

  def execute
    import_users
    import_categories
    import_posts
  end

  def import_users
    puts "", "creating users"
    total_count = mysql_query("SELECT count(*) count FROM users;").first["count"]

    batches(BATCH_SIZE) do |offset|
      results =
        mysql_query(
          "SELECT id, username, email, joined_at, last_seen_at
         FROM users
         LIMIT #{BATCH_SIZE}
         OFFSET #{offset};",
        )

      break if results.size < 1

      next if all_records_exist? :users, results.map { |u| u["id"].to_i }

      create_users(results, total: total_count, offset: offset) do |user|
        {
          id: user["id"],
          email: user["email"],
          username: user["username"],
          name: user["username"],
          created_at: user["joined_at"],
          last_seen_at: user["last_seen_at"],
          post_create_action:
            proc do |new_user|
              next if  user["avatar_url"].nil? || user["avatar_url"].empty?
              path = File.join(AVATAR_UPLOADS_DIR, user["avatar_url"])
              if File.exist?(path)
                begin
                  upload = create_upload(new_user.id, path, File.basename(path))
                  if upload.persisted?
                    new_user.create_user_avatar
                    new_user.user_avatar.update(custom_upload_id: upload.id)
                    new_user.update(uploaded_avatar_id: upload.id)
                  end
                rescue StandardError
                  # don't care
                end
              end
            end,
        }
      end
    end
  end

  def import_categories
    puts "", "importing top level categories..."

    categories =
      mysql_query(
        "
                              SELECT id, name, description, position
                              FROM tags
                              ORDER BY position ASC
                            ",
      ).to_a

    create_categories(categories) { |category| { id: category["id"], name: category["name"] } }

    puts "", "importing children categories..."

    children_categories =
      mysql_query(
        "
                                       SELECT id, name, description, position
                                       FROM tags
                                       ORDER BY position
                                      ",
      ).to_a

    create_categories(children_categories) do |category|
      {
        id: "child##{category["id"]}",
        name: category["name"],
        description: category["description"],
      }
    end
  end

  def import_posts
    puts "", "creating topics and posts"

    total_count = mysql_query("SELECT count(*) count from posts").first["count"]

    batches(BATCH_SIZE) do |offset|
      results =
        mysql_query(
          "
        SELECT p.id id,
               d.id topic_id,
               d.title title,
               d.first_post_id first_post_id,
               p.user_id user_id,
               p.content raw,
               p.created_at created_at,
               t.tag_id category_id
        FROM posts p,
             discussions d,
             discussion_tag t
        WHERE p.discussion_id = d.id
          AND t.discussion_id = d.id
        ORDER BY p.created_at
        LIMIT #{BATCH_SIZE}
        OFFSET #{offset};
      ",
        ).to_a

      break if results.size < 1
      next if all_records_exist? :posts, results.map { |m| m["id"].to_i }

      create_posts(results, total: total_count, offset: offset) do |m|
        skip = false
        mapped = {}

        mapped[:id] = m["id"]
        mapped[:user_id] = user_id_from_imported_user_id(m["user_id"]) || -1
        mapped[:raw] = process_FLARUM_post(m["raw"], m["id"])
        mapped[:created_at] = Time.zone.at(m["created_at"])

        if m["id"] == m["first_post_id"]
          mapped[:category] = category_id_from_imported_category_id("child##{m["category_id"]}")
          mapped[:title] = CGI.unescapeHTML(m["title"])
        else
          parent = topic_lookup_from_imported_post_id(m["first_post_id"])
          if parent
            mapped[:topic_id] = parent[:topic_id]
          else
            puts "Parent post #{m["first_post_id"]} doesn't exist. Skipping #{m["id"]}: #{m["title"][0..40]}"
            skip = true
          end
        end

        skip ? nil : mapped
      end
    end
  end

  def process_FLARUM_post(raw, import_id)
    s = raw.dup

    s.gsub!(/\\n/, "")

    s.gsub(%r{<C><s>`</s>(.*?)<e>`</e></C>}, '`\1`')

    s.gsub(%r{<LIST>(.*?)</LIST>}m) do |list|
      items = list.scan(%r{<LI><s>- </s>\s*(.*?)\s*</LI>}m).flatten
      "<ul>" + items.map { |item| "<li>#{item}</li>" }.join(" ") + "</ul>"
    end

    text.gsub!(/<SIZE size="[^"]*">|<\/SIZE>|<COLOR color="[^"]*">|<\/COLOR>|<CENTER>|<\/CENTER>|<RIGTH>|<\/RIGTH>|<LEFT>|<\/LEFT>/, '')

    s.gsub!(%r{<URL url="(.*?)"><s>\[</s>(.*?)<e>\]\(.*?\)</e></URL>}) do
      url = $1
      text = $2
      "[#{text}](#{url})"
    end

    s.gsub!(%r{<s>(\d*.\W*?)<\/s>}) do
      text = $1
      "text"
    end

    s.gsub!(%r{<URL url="(.*?)">(.*?)</URL>}) do
      url = $1
      "[#{url}](#{url})"
    end

    s.gsub!(%r{<IMG src="(.*?)">(.*?)</IMG>}) do
      url = $1
      "![image](#{url})"
    end

    s.gsub!(/\[youtube\](.*?)\[\\youtube\]/) do
      video_id = $1
      url = "https://www.youtube.com/watch?v=#{video_id}"
      "[#{url}](#{url})"
    end

    s.gsub!(/\[center\]\s*(.*?)\s*\[\/center\]/m) do |center|
      "[center]\n#{center.strip}\n[/center]"
    end
    
    s.gsub!(/\[right\]\s*(.*?)\s*\[\/right\]/m) do |right|
      "[right]\n#{right.strip}\n[/right]"
    end
    
    s.gsub!(/\[left\]\s*(.*?)\s*\[\/left\]/m) do |left|
      "[left]\n#{left.strip}\n[/left]"
    end

    s.gsub!(/\[quote\](.*?)\[\\quote\]/) do
      quote = $1
      "[quote]\n#{quote}\n[/quote]"
    end

    s.gsub!(/<\/?[^>]+>/, '')

    s
  end

  def mysql_query(sql)
    @client.query(sql, cache_rows: false)
  end
end

ImportScripts::FLARUM.new.perform
