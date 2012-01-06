Heroku buildpack: NES
======================

This is a [Heroku buildpack](http://devcenter.heroku.com/articles/buildpack) for NES roms. It uses [jsnes](https://github.com/bfirsh/jsnes) to run any NES roms that are pushed to a heroku application.

Usage
-----

### NES

Example Usage:

    $ ls
    game.nes

    $ heroku create --stack cedar --buildpack http://github.com/hone/heroku-buildpack-jsnes.git

    $ git push heroku master
    ...
    -----> Heroku receiving push
    -----> Fetching custom buildpack
    -----> NES game detected
    -----> Installing dependencies using Bundler version 1.1.rc
           Running: bundle install --without development:test --path vendor/bundle --deployment
           Fetching gem metadata from http://rubygems.org/..
           Installing rack (1.3.5)
           Using bundler (1.1.rc)
           Your bundle is complete! It was installed into ./vendor/bundle
           Cleaning up the bundler cache.
    -----> Discovering process types
           Procfile declares types -> (none)

The buildpack will detect your app as NES if it has a `*.nes` file in the root directory. 

