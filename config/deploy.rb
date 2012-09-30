require 'bundler/capistrano'

set :user, "deploy"
set :application, "alaveteli"

set :scm, :git   # Or: `accurev`, `bzr`, `cvs`, `darcs`, `git`, `mercurial`, `perforce`, `subversion` or `none`
set :repository,  "https://github.com/datauy/alaveteli.git"
set :git_enable_submodules, 1
set :branch, "master"
set :git_shallow_clone, 1
set :scm_verbose, true

role :web, "quesabes.org"                          # Your HTTP server, Apache/etc
role :app, "quesabes.org"                          # This may be the same as your `Web` server
role :db,  "quesabes.org", :primary => true # This is where Rails migrations will run

ssh_options[:user] = "deploy"
ssh_options[:forward_agent] = true
ssh_options[:keys] = [File.join(ENV["HOME"], ".ssh", "id_rsa")]
set :use_sudo, true

set :deploy_to, "/home/gaba/quesabes"
set :deploy_via, :export
set :keep_releases, 3

# role :db,  "your slave db-server here"

# if you want to clean up old releases on each deploy uncomment this:
# after "deploy:restart", "deploy:cleanup"

# Not in the rake namespace because we're also specifying app-specific arguments here
namespace :xapian do
  desc 'Rebuilds the Xapian index as per the ./scripts/rebuild-xapian-index script'
  task :rebuild_index do
    run "cd #{current_path} && bundle exec rake xapian:rebuild_index models='PublicBody User InfoRequestEvent' RAILS_ENV=#{rails_env}"
  end
end


namespace :deploy do
  desc 'Link configuration after a code update'
  task :symlink_configuration do
    links = {

    "#{shared_path}/system/config/database.yml" => "#{release_path}/config/database.yml",
    "#{shared_path}/system/config/general.yml" => "#{release_path}/config/general.yml",
    "#{shared_path}/system/config/i18n-routes.yml" => "#{release_path}/config/i18n-routes.yml",
    "#{shared_path}/system/config/rails_env.rb" => "#{release_path}/config/rails_env.rb",
    "#{shared_path}/system/xapiandbs" => "#{release_path}/vendor/plugins/acts_as_xapian/xapiandbs",
    "#{shared_path}/system/files" => "#{release_path}/files",
    "#{shared_path}/cache" => "#{release_path}/cache",
    "#{shared_path}/cache/zips/download" => "#{release_path}/public/download"
    }

    # "ln -sf <a> <b>" creates a symbolic link but deletes <b> if it already exists
    run links.map {|a| "ln -sf #{a.first} #{a.last}"}.join(";")
  end

  task :update_permissions do
      run "sudo chown -R www-data:deploy #{shared_path}"
      run "sudo chown -R www-data:deploy #{release_path}"
      run "sudo chmod -R ug+rw #{release_path}"
  end

  task :update_commonlibs do

  end

  task :update_theme do
      run "cd #{release_path} && sudo #{release_path}/script/plugin install 'git://github.com/mysociety/adminbootstraptheme.git'"
      run "cd #{release_path} && sudo #{release_path}/script/plugin install 'git://github.com/datauy/quesabes-theme.git'"
  end

  task :site_links do
    run "sudo ln -nfs #{release_path} /var/www/quesabes"
  end
end

# task to clean out all deployments (it keeps the last :keep_releases).
after "deploy:update", "deploy:cleanup"
after "deploy:update_code", "deploy:symlink_configuration"
after "deploy:symlink_configuration", "deploy:migrate"
after "deploy:migrate", "deploy:update_theme"
after "deploy:create_symlink", "deploy:site_links"
after "deploy:site_links", "deploy:update_permissions"

####################
#    Passenger     #
####################

namespace :passenger do
  desc "Reinicia la aplicacion"
  task :restart, :roles => :app, :except => { :no_release => true } do
    run "sudo touch /var/www/quesabes/tmp/restart.txt"
  end
end
