path = require 'path'
optimist = require 'optimist'
console = require 'console'
fs = require 'fs'
os = require 'os'
spawnArgs = require 'spawn-args'
{spawn} = require('child_process')
execSync = require('sync-exec')

Dredd = require './dredd'
interactiveConfig = require './interactive-config'
{applyLoggingOptions} = require './configuration'
configUtils = require './config-utils'
logger = require('./logger')

packageData = require('../package.json')


TERM_TIMEOUT = 1000
TERM_RETRY = 500


class DreddCommand
  constructor: (options = {}, @cb) ->
    @finished = false
    {@exit, @custom} = options

    @serverProcessEnded = false

    @setExitOrCallback()

    @custom ?= {}

    if not @custom.cwd or typeof @custom.cwd isnt 'string'
      @custom.cwd = process.cwd()

    if not @custom.argv or not Array.isArray @custom.argv
      @custom.argv = []

  setOptimistArgv: ->
    @optimist = optimist(@custom.argv, @custom.cwd)
    @cliArgv = @optimist.argv

    @optimist.usage('''
      Usage:
        $ dredd init

      Or:
        $ dredd <path or URL to API description document> <URL of tested server> [OPTIONS]

      Example:
        $ dredd ./api-description.apib http://localhost:3000 --dry-run
    ''')
      .options(Dredd.options)
      .wrap(80)

    @argv = @optimist.argv
    @argv = applyLoggingOptions(@argv)

  # Gracefully terminate server
  stopServer: (callback) ->
    logger.verbose('Gracefully terminating backend server process.')
    unless @serverProcess?
      logger.verbose('No backend server process.')
      return callback()

    term = =>
      logger.info('Sending SIGTERM to backend server process.')
      @serverProcess.kill 'SIGTERM'

    kill = =>
      logger.info('Killing backend server process.')
      @serverProcess.kill 'SIGKILL'

    start = Date.now()
    term()

    waitForServerTermOrKill = =>
      if @serverProcessEnded == true
        clearTimeout timeout
        logger.debug('Backend server process successfully terminated.')
        callback()
      else
        logger.debug('Backend server process haven\'t terminated yet.')
        if (Date.now() - start) < TERM_TIMEOUT
          term()
          timeout = setTimeout waitForServerTermOrKill, TERM_RETRY
        else
          kill()
          clearTimeout(timeout)
          callback()

    timeout = setTimeout waitForServerTermOrKill, TERM_RETRY

  # This thing-a-ma-bob here is only for purpose of testing
  # It's basically a dependency injection for the process.exit function
  setExitOrCallback: ->
    if not @cb
      if @exit and (@exit is process.exit)
        @sigIntEventAdd = true

      if @exit
        @_processExit = (exitStatus) =>
          logger.verbose("Exiting Dredd process with status '#{exitStatus}'.")
          logger.debug('Using configured custom exit() method to terminate the Dredd process.')
          @finished = true
          @stopServer =>
            @exit(exitStatus)
      else
        @_processExit = (exitStatus) =>
          logger.verbose("Exiting Dredd process with status '#{exitStatus}'.")
          logger.debug('Using native process.exit() method to terminate the Dredd process.')
          @stopServer ->
            process.exit exitStatus
    else
      @_processExit = (exitStatus) =>
        logger.verbose("Exiting Dredd process with status '#{exitStatus}'.")
        logger.debug('Using configured custom callback to terminate the Dredd process.')
        @finished = true
        if @sigIntEventAdded
          if @serverProcess?
            logger.verbose('Killing backend server process before Dredd exits.')
            @serverProcess.kill('SIGKILL')
          process.removeEventListener 'SIGINT', @commandSigInt
        @cb exitStatus
        return @

  moveBlueprintArgToPath: ->
    # transform path and p argument to array if it's not
    if !Array.isArray(@argv['path'])
      @argv['path'] = @argv['p'] = [@argv['path']]

  checkRequiredArgs: ->
    argError = false

    # if 'blueprint' is missing
    if not @argv._[0]?
      console.error("\nError: Must specify path to API description document.")
      argError = true

    # if 'endpoint' is missing
    if not @argv._[1]?
      console.error("\nError: Must specify URL of the tested API instance.")
      argError = true

    # show help if argument is missing
    if argError
      console.error("\n")
      @optimist.showHelp(console.error)
      return @_processExit(1)

  runExitingActions: ->
    # run interactive config
    if @argv["_"][0] == "init" or @argv.init == true
      logger.silly('Starting interactive configuration.')
      @finished = true
      interactiveConfig.run @argv, (config) =>
        configUtils.save(config)
        console.log ""
        console.log "Configuration saved to dredd.yml"
        console.log ""
        if config['language'] == "nodejs"
          console.log "Run test now, with:"
        else
          console.log "Install hooks handler and run Dredd test with:"
        console.log ""
        if config['language'] == 'ruby'
          console.log "  $ gem install dredd_hooks"
        else if config['language'] == 'python'
          console.log "  $ pip install dredd_hooks"
        else if config['language'] == 'php'
          console.log "  $ composer require ddelnano/dredd-hooks-php --dev"
        else if config['language'] == 'perl'
          console.log "  $ cpanm Dredd::Hooks"
        else if config['language'] == 'go'
          console.log "  $ go get github.com/snikch/goodman"

        console.log "  $ dredd"
        console.log ""

        return @_processExit(0)

    # show help
    else if @argv.help is true
      logger.silly('Printing help.')
      @optimist.showHelp(console.error)
      return @_processExit(0)

    # show version
    else if @argv.version is true
      logger.silly('Printing version.')
      console.log("""\
        #{packageData.name} v#{packageData.version} \
        (#{os.type()} #{os.release()}; #{os.arch()})
      """)
      return @_processExit(0)

  loadDreddFile: ->
    configPath = @argv.config
    logger.verbose('Loading configuration file:', configPath)

    if configPath and fs.existsSync configPath
      logger.info("Configuration '#{configPath}' found, ignoring other arguments.")
      @argv = configUtils.load(configPath)

    # overwrite saved config with cli arguments
    for key, value of @cliArgv
      if key != "_" and key != "$0"
        @argv[key] = value

    @argv = applyLoggingOptions(@argv)

  parseCustomConfig: ->
    @argv.custom = configUtils.parseCustom @argv.custom

  runServerAndThenDredd: (callback) ->
    if not @argv['server']?
      logger.verbose('No backend server process specified, starting testing at once.')
      @runDredd @dreddInstance
    else
      logger.verbose('Backend server process specified, starting backend server and then testing.')

      parsedArgs = spawnArgs(@argv['server'])
      command = parsedArgs.shift()

      @serverProcess = spawn command, parsedArgs

      logger.info("Starting backend server process with command: #{@argv['server']}")

      @serverProcess.stdout.setEncoding 'utf8'

      @serverProcess.stdout.on 'data', (data) ->
        process.stdout.write data.toString()

      @serverProcess.stderr.setEncoding 'utf8'

      @serverProcess.stderr.on 'data', (data) ->
        process.stdout.write data.toString()

      @serverProcess.on 'close' , (status) =>
        @serverProcessEnded = true
        if status?
          logger.info('Backend server process exited.')
        else
          logger.info('Backend server process was killed.')


      @serverProcess.on 'error', (error) =>
        logger.error('Command to start backend server process failed, exiting Dredd.')
        @_processExit(2)

      # Ensure server is not running when dredd exits prematurely somewhere
      process.on 'beforeExit', =>
        if @serverProcess?
          logger.verbose('Killing backend server process before Dredd exits.')
          @serverProcess.kill('SIGKILL')

      # Ensure server is not running when dredd exits prematurely somewhere
      process.on 'exit', =>
        if @serverProcess?
          logger.verbose('Killing backend server process on Dredd\'s exit.')
          @serverProcess.kill('SIGKILL')

      waitSecs = parseInt(@argv['server-wait'], 10)
      waitMilis = waitSecs * 1000
      logger.info("Waiting #{waitSecs} seconds for backend server process to start.")

      @wait = setTimeout =>
        @runDredd @dreddInstance
      , waitMilis

  # This should be handled in a better way in the future:
  # https://github.com/apiaryio/dredd/issues/625
  logDebuggingInfo: (config) ->
    logger.debug('Dredd version:', packageData.version)
    logger.debug('Node.js version:', process.version)
    logger.debug('Node.js environment:', process.versions)
    logger.debug('System version:', os.type(), os.release(), os.arch())
    try
      npmVersion = execSync('npm --version').stdout.trim()
      logger.debug('npm version:', npmVersion or 'unable to determine npm version')
    catch err
      logger.debug('npm version: unable to determine npm version:', err)
    logger.debug('Configuration:', JSON.stringify(config))

  run: ->
    for task in [
      @setOptimistArgv
      @parseCustomConfig
      @runExitingActions
      @loadDreddFile
      @checkRequiredArgs
      @moveBlueprintArgToPath
    ]
      task.call @
      return if @finished

    configurationForDredd = @initConfig()
    @logDebuggingInfo(configurationForDredd)
    @dreddInstance = @initDredd(configurationForDredd)

    try
      @runServerAndThenDredd()
    catch e
      logger.error(e.message, e.stack)
      @stopServer =>
        @_processExit(2)
    return

  lastArgvIsApiEndpoint: ->
    # when API description path is a glob, some shells are automatically expanding globs and concating
    # result as arguments so I'm taking last argument as API endpoint server URL and removing it
    # from optimist's args
    @server = @argv._[@argv._.length - 1]
    @argv._.splice(@argv._.length - 1, 1)
    return @

  takeRestOfParamsAsPath: ->
    # and rest of arguments concating to 'path' and 'p' opts, duplicates are filtered out later
    @argv['p'] = @argv['path'] = @argv['path'].concat(@argv._)
    return @

  initConfig: ->
    @lastArgvIsApiEndpoint().takeRestOfParamsAsPath()

    configuration =
      'server': @server
      'options': @argv

    # push first argument (without some known configuration --key) into paths
    configuration.options.path ?= []
    configuration.options.path.push @argv._[0]

    configuration.custom = @custom

    return configuration

  initDredd: (configuration) ->
    return new Dredd(configuration)

  commandSigInt: ->
    logger.error('\nShutting down from keyboard interruption (Ctrl+C)')
    @dreddInstance.transactionsComplete => @_processExit(0)

  runDredd: (dreddInstance) ->
    if @sigIntEventAdd
      # handle SIGINT from user
      @sigIntEventAdded = !@sigIntEventAdd = false
      process.on 'SIGINT', @commandSigInt

    logger.verbose('Running Dredd instance.')
    dreddInstance.run (error, stats) =>
      logger.verbose('Dredd instance run finished.')
      @exitWithStatus(error, stats)

    return @

  exitWithStatus: (error, stats) ->
    if error
      logger.error(error.message) if error.message
      return @_processExit(1)

    if (stats.failures + stats.errors) > 0
      @_processExit(1)
    else
      @_processExit(0)
    return


exports = module.exports = DreddCommand
