{CompositeDisposable} = require 'atom'
{File}                = require 'atom'
fs                    = require 'fs'
path                  = require 'path'
request               = require 'request'
Archiver              = require 'archiver'
Config                = require 'electron-config'
RokuDevelopView       = require './roku-develop-view.coffee'
RokuDeviceTable       = require './roku-develop-devtable.coffee'
RokuSSDP              = require './roku-develop-ssdp.coffee'
util                  = require 'util'

module.exports        = RokuDevelop =

  excludedPaths:       null
  excludedPathList:    null
  zipFileDirectory:    null
  rokuUserId:          null
  rokuPassword:        null
  manifestBuild:       null
  saveOnDeploy:        null
  homeBeforeDeploy:    null
  autoDiscover:        null
  rokuDeviceTable:     null
  rokuDevelopView:     null
  subscriptions:       null
  myConfig:            null
  panel:               null
  rokuIPList:          null
  projectDirectory:    null
  zipFilePath:         null
  rokuPackagePassword: null

  # Package config schema (Settings)
  config:
    excludedPaths:
      title: 'Excluded Paths (comma-separated list)'
      description: 'dot-files and Zip File Directory
                    are automatically excluded'
      type: 'string'
      default: ''
      order: 1
    zipFileDirectory:
      title: 'Zip File Directory (absolute path or project dir relative path)'
      description: 'parent directory must already exist'
      type: 'string'
      default: 'out'
      order: 2
    rokuUserId:
      type: 'string'
      default: 'rokudev'
      order: 3
    rokuPassword:
      type: 'string'
      default: ''
      order: 4
    rokuPackagePassword:
      type: 'string'
      default: ''
      order: 5
    manifestBuild:
      title: 'Increment manifest build_version'
      type: 'integer'
      default: 0
      enum: [
        {value: 0, description: 'Do not increment'}
        {value: 1, description: 'Increment'}
        {value: 2, description: 'Use date: yyyymmdd'}
        {value: 3, description: 'Use date/time: yymmddhhmm'}
      ]
      order: 6
    saveOnDeploy:
      title: 'Save On Deploy (saves current file before deployment)'
      type: 'boolean'
      default: true
      order: 7
    homeBeforeDeploy:
      title: 'Send Home Keypress Before Deploy'
      description: 'Use if deploying a Scene Graph channel
                    causes the Roku to crash'
      type: 'boolean'
      default: false
      order: 8
    autoDiscover:
      title: 'Automatically discover Rokus on the local network'
      description: 'Un-check to only allow manual device entry'
      type: 'boolean'
      default: true
      order: 9

  #
  # Invoked by Atom one time only, when an activation command is issued
  # Activation commands are specified in package.json
  #
  activate: (state) ->
    if state and state.view
      viewState = state.view
    else
      viewState = null

    # Get Atom config data, and add event-handlers for config updates

    @excludedPaths       = atom.config.get 'roku-develop.excludedPaths'
    @excludedPathList    = (item.trim() for item in @excludedPaths.split ',')
    @zipFileDirectory    = atom.config.get 'roku-develop.zipFileDirectory'
    @rokuUserId          = atom.config.get 'roku-develop.rokuUserId'
    @rokuPassword        = atom.config.get 'roku-develop.rokuPassword'
    @manifestBuild       = atom.config.get 'roku-develop.manifestBuild'
    @saveOnDeploy        = atom.config.get 'roku-develop.saveOnDeploy'
    @homeBeforeDeploy    = atom.config.get 'roku-develop.homeBeforeDeploy'
    @autoDiscover        = atom.config.get 'roku-develop.autoDiscover'
    @rokuPackagePassword = atom.config.get 'roku-develop.rokuPackagePassword'

    atom.config.observe 'roku-develop.excludedPaths', (newValue) =>
      @excludedPaths = newValue
      @excludedPathList = (item.trim() for item in @excludedPaths.split ',')

    atom.config.observe 'roku-develop.zipFileDirectory', (newValue) =>
      @zipFileDirectory = newValue

    atom.config.observe 'roku-develop.rokuUserId', (newValue) =>
      @rokuUserId = newValue

    atom.config.observe 'roku-develop.rokuPassword', (newValue) =>
      @rokuPassword = newValue

    atom.config.observe 'roku-develop.manifestBuild', (newValue) =>
      @manifestBuild = newValue

    atom.config.observe 'roku-develop.saveOnDeploy', (newValue) =>
      @saveOnDeploy = newValue

    atom.config.observe 'roku-develop.homeBeforeDeploy', (newValue) =>
      @homeBeforeDeploy = newValue

    atom.config.observe 'roku-develop.autoDiscover', (newValue) =>
      # If auto-discovery was previously disabled, but is now being enabled,
      # then initiate SSDP discovery
      if not @autoDiscover and newValue
        RokuSSDP.discover @discoveryCallback.bind(this)
      @autoDiscover = newValue

    atom.config.observe 'roku-develop.rokuPackagePassword', (newValue) =>
      @rokuPackagePassword = newValue

    # Use a config file in Atom's config directory to persist the device table
    @myConfig = new Config({name: 'roku-develop-config'})
    console.log 'Using config file:', @myConfig.path

    # Construct an empty device table
    @rokuDeviceTable = new RokuDeviceTable

    # Restore device table from config file
    deviceTableJsonString = @myConfig.get 'deviceTableJsonString'
    @rokuDeviceTable.fromJsonString deviceTableJsonString

    # The view sets up the DOM element used for the displayed device list
    @rokuDevelopView = new RokuDevelopView(viewState,
                                           @newDeviceCallback.bind(this),
                                           @clearDevicesCallback.bind(this))

    # Place the view's DOM element in a panel at the bottom of the editor pane
    @panel = atom.workspace.addBottomPanel({item: @rokuDevelopView.getElement()
                                            , visible: false})

    # Update the view with the saved device table
    @rokuDevelopView.update @rokuDeviceTable

    # Facilitate cleanup of subscribed events
    @subscriptions = new CompositeDisposable

    # Register commands

    @subscriptions.add atom.commands.add  'atom-workspace',
                                          'roku-develop:toggle': => @toggle()

    @subscriptions.add atom.commands.add  'atom-workspace',
                                          'roku-develop:deploy': => @deploy()

    @subscriptions.add atom.commands.add  'atom-workspace',
                                          'roku-develop:package': => @package()

    # Initiate device discovery
    # 'bind' ensures callback executes in the context of the main package code
    # Do not initiate SSDP discovery if automatic discovery is turned off
    if @autoDiscover
      RokuSSDP.discover @discoveryCallback.bind(this)

  #
  # Invoked by Atom upon shutdown
  #
  deactivate: ->
    # Persist the device table to the config file
    @myConfig.set 'deviceTableJsonString', @rokuDeviceTable.toJsonString()
    @subscriptions.dispose()
    @panel.destroy()
    @rokuDevelopView.destroy()

  #
  # Called by Atom before the package is deactivated
  # Any JSON returned here will be passed as an argument to activate()
  # the next time the package is loaded
  #
  serialize: -> {
    view: @rokuDevelopView.serialize()
  }

  #
  # Called from the view when a new device has been manually entered
  #
  newDeviceCallback: (ip) ->
    if @validIP ip
      RokuSSDP.ecp ip, @discoveryCallback.bind(this)
    else
      console.warn 'newDeviceCallback - invalid IP address', ip

  #
  # Called from the view when the Clear List button is pressed
  #
  clearDevicesCallback: ->
    @rokuDeviceTable = new RokuDeviceTable

  #
  # Invoked when the roku-develop:toggle command is issued
  #
  toggle: ->
    if @panel.isVisible() then @panel.hide() else @panel.show()

  #
  # Invoked when the roku-develop:deploy command is issued
  #
  deploy: ->
    if not @checkSettings()
      return

    # Show a deploy message here. Async operations can cause the other
    # message to be delayed, appearing like a failure.
    atom.notifications.addInfo 'Starting deploy'

    # Compress the project directory, deploying when finished
    try
      @compressProject()
    catch e
      console.warn 'Exception when creating zip file: %O', e
      atom.notifications.addError 'Exception when creating zip file',
                                  {dismissable: true, detail: e.message}

  #
  # Invoked when the roku-develop:package command is issued
  #
  package: ->
    if not @checkSettings()
      return

    if not @rokuPackagePassword
      atom.notifications.addWarning 'Package password not set',
                                    {
                                      dismissable: true,
                                      detail: 'Go to settings > Packages >
                                               roku-develop'
                                    }
      return

    # Check that only one discovered device is selected
    if @rokuIPList.length != 1
      atom.notifications.addWarning 'Only one device should be selected for
                                     packaging', {dismissable: true}
      return

    # Ensure the project directory is set
    if not @findProjectDirectory()
      return

    atom.notifications.addInfo 'Packaging application'

    @getPackageAppName (error, appName) =>
      if error
        atom.notifications.addWarning 'Failed to get package name',
          {dismissable: true, detail: error.message}
        return
      # Send the package post request
      ip = @rokuIPList[0]
      url = "http://#{ip}/plugin_package"
      form = {
        mysubmit: 'Package',
        pkg_time: new Date().getTime().toString(),
        app_name: appName,
        passwd: @rokuPackagePassword
      }
      auth = {
        user: @rokuUserId,
        pass: @rokuPassword,
        sendImmediately: false
      }
      request.post {url: url, timeout: 15000, formData: form, auth: auth}, \
          (error, response, body) =>
        if error or not response or response.statusCode != 200 or not body
          atom.notifications.addWarning 'Failed to package application',
            {dismissable: true, detail: if error then error.message else ""}
        else if body.toUpperCase().indexOf('HTTP-EQUIV="REFRESH"') != -1
          atom.notifications.addWarning 'No application installed',
            {dismissable: true, detail: 'Deploy first'}
        else if body.toUpperCase().indexOf('SUCCESS') != -1
          packageNameRegex = /\/([^\/]*\.pkg)"/im
          matcher = packageNameRegex.exec body
          if matcher and matcher.length == 2
            @downloadPackage ip, matcher[1]
          else
            atom.notifications.addWarning 'Failed to parse response for
                                           package name', {dismissable: true}
        else
          atom.notifications.addWarning 'Failed to package application',
            {dismissable: true}

  #
  # Try to download a package from a roku
  #
  downloadPackage: (ip, packageName) ->
    url = "http://#{ip}/pkgs/#{packageName}"
    auth = {
      user: @rokuUserId,
      pass: @rokuPassword,
      sendImmediately: false
    }
    request.get {url: url, timeout: 15000, auth: auth, encoding: null}, \
        (error, response, body) =>
      if error or not response or response.statusCode != 200 or not body
        atom.notifications.addWarning 'Failed to download application package',
          {dismissable: true, detail: if error then error.message else ""}
        return
      outPath = @getZipFilePath packageName
      if not outPath
        return
      fs.writeFile outPath, body, (error) =>
        if error
          atom.notifications.addInfo 'Failed to write package',
            {dismissable: true, detail: error.message}
          return
        atom.notifications.addInfo 'Finished packaging application',
          {dismissable: true}

  #
  # Get the application name in the format "Name/Version" from the manifest
  # data
  #
  getPackageAppName: (callback) ->
    manifestPath = path.join @projectDirectory.getRealPathSync(), 'manifest'
    fs.readFile manifestPath, 'utf8', (error, data) =>
      if error
        callback(error)
      else
        entriesRegex = /^([^\s=]+)\s*=(.*)$/gim
        matches = null
        title = null
        major_version = null
        minor_version = null
        build_version = null
        matches = true
        while matches
          matches = entriesRegex.exec data
          if matches and matches.length == 3
            key = matches[1]
            val = matches[2]
            if key == 'title'
              title = val
            else if key == 'screensaver_title' and not title
              title = val
            else if key == 'major_version'
              major_version = val
            else if key == 'minor_version'
              minor_version = val
            else if key == 'build_version'
              build_version = val
        if not title or not major_version or not minor_version or
            not build_version
          callback(new Error('Could not determine app title and version from
                              manifest'))
          return
        callback(null, util.format("%s/%s.%s.%s", title, major_version,
          minor_version, build_version))


  #
  # Check for a set password and at least one deploy device
  # Returns false on error
  #
  checkSettings: ->
    # Make sure the password is set up
    if not @rokuPassword
      atom.notifications.addWarning 'You must set your password
                                     on the Settings page (Ctrl+comma)',
                                    {
                                      dismissable: true
                                      detail: 'Go to Settings page > Packages
                                              > roku-develop'
                                    }
      return false

    # Check that at least one device exists
    if @rokuDeviceTable.getValues().length < 1
      atom.notifications.addWarning 'No devices found', {dismissable: true}
      return false

    # Get the list of deployment ip addresses
    @rokuIPList = (entry.ipAddr for entry in @rokuDeviceTable.getValues() \
                    when entry.deploy)

    # Check that at least one discovered device is selected
    if @rokuIPList.length < 1
      atom.notifications.addWarning 'No devices marked for deployment',
                                    {dismissable: true}
      return false
    return true
  #
  # Called from RokuSSDP whenever a device has been discovered
  # If this is an automatically-discovered device,
  # only add to the device table if autoDiscover is enabled
  #
  discoveryCallback: (details, autoDiscovered) ->
    if not autoDiscovered or @autoDiscover
      # Update the device table with the new device details
      deviceTableChanged = @rokuDeviceTable.add details
      if deviceTableChanged
        # Update the view only if the device table has changed
        @rokuDevelopView.update @rokuDeviceTable
        # Persist the device table to the config file
        @myConfig.set 'deviceTableJsonString', @rokuDeviceTable.toJsonString()

  #
  # Return true if an ip address is of the form: aaa.bbb.ccc.ddd
  #
  validIP: (ip) ->
    /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test ip

  #
  # Get the name of the folder containing the current file being edited
  # Check that the folder contains a 'source' directory
  # If the folder does not contain a 'source' directory,
  # search up the directory tree to find one
  # This allows the user to have multiple Roku projects open in Atom
  #
  compressProject: ->
    # Don't attempt to compress a project without a 'source' directory
    if not @findProjectDirectory()
      return

    # Determine the zip file's path name, creating the directory if necessary
    @zipFilePath = @getZipFilePath()
    if not @zipFilePath
      return

    # Save the file -- this will update the timestamp even if nothing changed
    if @saveOnDeploy
      try
        atom.workspace.getActiveTextEditor().save()
      catch e
        console.warn 'Can\'t save this file: %O', e
        atom.notifications.addError 'Can\'t save this file.
                                     Check you have write access to the file',
                                    {dismissable: true, detail: e.message}
        return

    # Increment the build number in the manifest file, then continue deployment
    @incrementManifestBuild()

  #
  # Try to find the project directory by searching up the hierarchy from the
  # active file's path. Sets @projectDirectory. Returns false on failure.
  #
  findProjectDirectory: ->
    # Get the active TextEditor object
    activeTextEditor = atom.workspace.getActiveTextEditor()

    # If we're on the Settings View or Markdown View,
    # for example, there won't be an active TextEditor
    if not activeTextEditor
      atom.notifications.addWarning 'Project can only be deployed
                                    from within an Editor window',
                                    {dismissable: true}
      return

    # Get the path of the file being edited
    activePath = activeTextEditor.getPath()

    # There won't be an active file if editing a new 'untitled' file
    if not activePath
      atom.notifications.addWarning 'Project can only be deployed
                                    when editing an existing project file',
                                    {dismissable: true}
      return

    # Create a File object so we can get the current file's parent directory
    activeFile = new File activePath, false

    if not activeFile
      atom.notifications.addError 'Unable to create File obj from path name',
                                  {dismissable: true}
      return

    # Get the current file's parent directory
    @projectDirectory = activeFile.getParent()

    # Search up the filesystem hierarchy looking for a 'source' directory
    while not @projectDirectory.isRoot() and
          not @projectDirectory.getSubdirectory('source').existsSync()
      @projectDirectory = @projectDirectory.getParent()

    # Fail if it does not exist
    if not @projectDirectory.getSubdirectory('source').existsSync()
      atom.notifications.addWarning 'Cannot find project source directory',
                        {detail: 'Open a project file before deploying',
                        dismissable: true}
      return false
    return true

  #
  # Auto-increment the manifest build number if necessary, then deploy
  #
  incrementManifestBuild: ->

    # Read the manifest file; don't compress unless manifest is found
    manifestPath = path.join @projectDirectory.getRealPathSync(), 'manifest'
    fs.readFile manifestPath, 'utf8', (e, data) =>
      if e
        console.warn 'Error reading manifest file: %O', e
        atom.notifications.addWarning 'Unable to read manifest file',
                                      {dismissable: true, detail: e.message}
      else
        # 0 => Don't increment build_version
        # 1 => Increment build_version
        # 2 => Use date as build_version
        # 3 => Use date/time as build_version
        if @manifestBuild < 1 or @manifestBuild > 3
          @createZip()
        else
          reBuildVersion = /^build_version\s*=(.*)$/im
          ma = reBuildVersion.exec data
          if Array.isArray(ma) and ma.length is 2
            if @manifestBuild is 1
              oldBuildVersion = ma[1]
              newBuildVersion = parseInt(oldBuildVersion, 10) + 1
              newBuildVersion = 0 if isNaN(newBuildVersion)
            else if @manifestBuild is 2
              newBuildVersion = @dateNowFormat()
            else
              newBuildVersion = @dateTimeNowFormat()

            data = data.replace reBuildVersion,
                                'build_version=' + newBuildVersion
            fs.writeFile manifestPath, data, 'utf8', (e) =>
              if e
                console.warn 'Can\'t update manifest file: %O', e
                atom.notifications.addError 'Can\'t update manifest file.
                                             Check you have write access
                                             to the manifest file',
                                        {dismissable: true, detail: e.message}
              else
                @createZip()
          else
            atom.notifications.addWarning 'No manifest build_version found',
                                          {dismissable: true}

  createZip: ->

    # Archiver writes to a writeable stream
    outputStream = fs.createWriteStream @zipFilePath

    # When the project finishes compressing, the output stream will close
    # Deploy the compressed zip file to the Roku devices
    outputStream.on 'close', =>
      @deployZip()

    outputStream.on 'error', (e) =>
      atom.notifications.addError 'Archive output stream error',
                                  {dismissable: true, detail: e.message}
      archive?.abort()

    # Use the archiver package to create a zip of the project directory
    # Note that the forceLocalTime zip option doesn't appear to work,
    # so the files in the zip bundle may have UTC timestamps
    archive = Archiver('zip', {forceLocalTime: true})

    archive.on 'error', (e) =>
      console.warn 'Archive error: %O', e
      atom.notifications.addError 'Archive error',
                                  {dismissable: true, detail: e.message}
      return false

    archive.pipe outputStream

    @getRokuDevIgnores (rokuDevIgnores) =>
      console.debug(rokuDevIgnores)
      # Compile a list of files and directories to be compressed
      @addFilesToArchive archive, @projectDirectory, rokuDevIgnores, false

      # Finish the compression, calling the output stream's close handler
      archive.finalize()

    return true

  addFilesToArchive: (archive, parentEntry, rokuDevIgnores, beingIgnored) ->
    zipDirectoryPath = path.dirname @zipFilePath
    projectPath = @projectDirectory.getPath()

    for entry in parentEntry.getEntriesSync()
      entryPath = entry.getPath()
      baseName = entry.getBaseName()
      pathname = entry.getRealPathSync()
      relPath = path.normalize(path.relative(projectPath, entryPath)).replace(/\\/g, '/')

      if not (baseName.startsWith '.') and (baseName not in @excludedPathList)
        ignore = beingIgnored and not (relPath in rokuDevIgnores.unignores and relPath not in rokuDevIgnores.ignores)
        ignore = ignore or (not beingIgnored and relPath in rokuDevIgnores.ignores)

        if entry.isFile() and not ignore and pathname isnt @zipFilePath
          archive.file pathname, {name: entryPath.replace(projectPath, '')}

        else if entry.isDirectory() and pathname isnt zipDirectoryPath and entryPath isnt zipDirectoryPath
          @addFilesToArchive archive, entry, rokuDevIgnores, ignore

  #
  # Return an associative array with the fields "ignores" and "unignores"
  # containing arrays of files to be ignored or not ignored when archiving
  # for deployment
  #
  getRokuDevIgnores: (callback) ->
    # Read the .rokudevignore file if it is available
    rokuDevIgnorePath = path.join @projectDirectory.getRealPathSync(),
      '.rokudevignore'
    fs.readFile rokuDevIgnorePath, 'utf8', (e, data) =>
      if e
        console.debug('No ignore file loaded at %s', rokuDevIgnorePath)
        callback {
          ignores: [],
          unignores: []
        }
      else
        ignores = []
        unignores = []
        ignoresLines = data.split(/[\r?\n?]+/)
        for ignore in ignoresLines
          ignore = ignore.trim()
          if ignore.endsWith('/')
            ignore = ignore.substring(0, ignore.length - 1)
          if ignore.length == 0
            continue
          else if ignore.startsWith('#')
            continue
          else if ignore.startsWith('!')
            unignores.push(ignore.replace('!', ''))
          else
            ignores.push(ignore)
        callback {
          ignores: ignores,
          unignores: unignores
        }

  #
  # Determine the pathname used for the compressed zip file
  #
  getZipFilePath: (name) ->
    name = name or "bundle.zip"
    zipFileDirectoryNorm = path.normalize @zipFileDirectory.trim()
    if path.isAbsolute zipFileDirectoryNorm
      zipDirectoryPath = zipFileDirectoryNorm
    else
      zipDirectoryPath = path.join @projectDirectory.getRealPathSync()
                                   , zipFileDirectoryNorm

    zipFilePath = path.join zipDirectoryPath, name

    # Check if output directory already exists
    try
      stats = fs.statSync zipDirectoryPath
    catch e
      stats = null

    # Create output directory if it does not already exist
    if not stats or not stats.isDirectory()
      console.log zipDirectoryPath + ' does not exist or is not directory'
      try
        fs.mkdirSync zipDirectoryPath
      catch e
        console.warn 'Unable to create output directory: %O', e
        atom.notifications.addError 'Unable to create output directory',
                                    {dismissable: true, detail: e.message}
        return ''

    return zipFilePath

  #
  # Deploy the zip file to all selected Roku devices
  #
  deployZip: ->
    atom.notifications.addInfo 'Deploying project to selected devices'
    for ip in @rokuIPList
      if @homeBeforeDeploy
        @homeKeypress ip, 2
      else
        @uploadToDevice(ip)

  #
  # Send an ECP command so device exits to Home screen before deploying
  # Use two Home keypresses: one to exit the screensaver, one to get to Home
  #
  homeKeypress: (ip, num) ->

    url = "http://#{ip}:8060/keypress/Home"

    request.post({url: url, timeout: 15000}, (error, response, body) =>
      if error
        atom.notifications.addWarning 'Unable to connect to ' + ip + ': '+ error.message,
                                      {dismissable: true}
      else if not response
        atom.notifications.addWarning 'No response received from ' + ip,
                                      {dismissable: true}
      else if response.statusCode isnt 200 and response.statusCode isnt 202
        atom.notifications.addWarning 'Bad response code ' +
                                      response.statusCode +
                                      ' from ' + ip, {dismissable: true}
      else
        if --num > 0
          # First Home keypress exits screensaver, 2nd one exits channel
          @homeKeypress ip, num
        else
          # Delay before uploading package to device
          setTimeout ( => @uploadToDevice(ip) ), 2500
    )

    return

  #
  # Upload the compressed zip file to a Roku device
  #
  uploadToDevice: (ip) ->
    url = "http://#{ip}/plugin_install"

    formData =
      mysubmit: 'Replace'
      archive: fs.createReadStream @zipFilePath

    auth =
      'user': @rokuUserId
      'pass': @rokuPassword
      'sendImmediately': false

    #request.post {url: url, formData: formData, auth: auth, timeout: 15000}
    request.post {url: url, formData: formData, auth: auth, timeout: 60000}
                  ,(error, response, body) =>
      console.log 'error', error
      console.log 'response', response
      console.log 'body', body
      if error
        atom.notifications.addWarning 'Upload error for ' + ip +
                                      ': ' + error.message,
                                      {dismissable: true}
      else if not response
        atom.notifications.addWarning 'No upload response from ' + ip,
                                      {dismissable: true}
      else if response.statusCode is 401
        atom.notifications.addWarning 'Authorization error ' +
                                      response.statusCode + ' from ' + ip,
                                      {
                                        dismissable: true,
                                        detail: 'Make sure you entered
                                                your Roku user id and password
                                                \non the Settings page.'
                                      }
      else if response.statusCode isnt 200 and response.statusCode isnt 202
        atom.notifications.addWarning 'Bad upload response code ' +
                                      response.statusCode + ' from ' + ip,
                                      {dismissable: true}
      else
        # Look for Roku.Message in the response body for non-legacy Rokus
        msgList = []
        re = /'Roku\.Message'[\s\S]*?'Set message content'[\s\S]+?'([^']+)'/ig
        while ma = re.exec body
          if Array.isArray(ma) and ma.length is 2
            msgList.push ma[1]

        # Handle responses from legacy Roku devices
        if msgList.length < 1
          re = /<font color="red">([\s\S]+?)<\/font>/ig
          while ma = re.exec body
            if Array.isArray(ma) and ma.length is 2
              msgList.push ma[1]

        # Display Atom notification for each message
        for msg in msgList
          if /fail/i.test msg
            atom.notifications.addWarning ip+ ': ' + msg, {dismissable: true}
          else if /received/i.test msg
            atom.notifications.addSuccess ip + ': ' + msg
          else
            atom.notifications.addInfo ip + ': ' + msg

  #
  # Get local date in the form yyyymmdd
  #
  dateNowFormat: ->
    dt = new Date()

    (@zeroFill dt.getFullYear(), 4) +
    (@zeroFill dt.getMonth() + 1, 2) +
    (@zeroFill dt.getDate(), 2)

  #
  # Get local date/time in the form yymmddhhmmss
  #
  dateTimeNowFormat: ->
    dt = new Date()

    (@zeroFill dt.getFullYear(), 2) +
    (@zeroFill dt.getMonth() + 1, 2) +
    (@zeroFill dt.getDate(), 2) +
    (@zeroFill dt.getHours(), 2) +
    (@zeroFill dt.getMinutes(), 2)

  #
  # Return a string of 'width' chars padded with leading zeroes
  #
  zeroFill: (number, width) ->
    ('0'.repeat(width - 1) + number).slice(-width)
