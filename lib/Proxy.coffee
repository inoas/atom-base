fs            = require 'fs'
stream        = require 'stream'
child_process = require 'child_process'

module.exports =

##*
# Proxy that handles communicating with the PHP side.
##
class Proxy
    ###*
     * The config to use.
    ###
    config: null

    ###*
     * The name (without path or extension) of the database file to use.
    ###
    indexDatabaseName: null

    ###*
     * The name of the project.
    ###
    projectName: null

    ###*
     * Constructor.
     *
     * @param {Config} config
    ###
    constructor: (@config) ->

    ###*
     * Prepares parameters for execution.
     *
     * @param {Array} parameters
     *
     * @return {Array}
    ###
    prepareParameters: (args) ->
        parameters = [
            '-d memory_limit=-1',
            @getCorePackagePath() + "/src/Main.php"
        ]

        for a in args
            parameters.push(a)

        return parameters

    ###*
     * @return {String}
    ###
    getCorePackagePath: () ->
        return atom.packages.resolvePackagePath("php-integrator-core")

    ###*
     * Performs an asynchronous request to the PHP side.
     *
     * @param {String}   command        The command to execute.
     * @param {Array}    parameters     The arguments to pass.
     * @param {Callback} streamCallback A method to invoke each time streaming data is received.
     * @param {String}   stdinData      The data to pass to STDIN.
     *
     * @return {Promise}
    ###
    performRequestAsync: (command, parameters, streamCallback = null, stdinData = null) ->
        return new Promise (resolve, reject) =>
            if not @getCorePackagePath()?
                reject('''
                    The core package was not found, it is currently being installed. This only needs to happen once at
                    initialization, but the service is not available yet in the meantime.
                ''')
                return

            proc = child_process.spawn(command, parameters)

            buffer = ''
            errorBuffer = ''

            proc.stdout.on 'data', (data) =>
                buffer += data

            proc.on 'close', (code) =>
                if errorBuffer or not buffer or buffer.length == 0
                    @showUnexpectedOutputError(errorBuffer, parameters)
                    reject({rawOutput: buffer, message: "No output received from the PHP side!"})
                    return

                try
                    response = JSON.parse(buffer)

                catch error
                    @showUnexpectedOutputError(buffer, parameters)

                if not response or not response.success
                    reject({rawOutput: buffer, message: 'An unsuccessful status code was returned by the PHP side!'})
                    return

                resolve(response.result)

            if streamCallback
                proc.stderr.on 'data', (data) =>
                    streamCallback(data)

            else
                proc.stderr.on 'data', (data) =>
                    errorBuffer += data

            if stdinData?
                proc.stdin.write(stdinData, 'utf-8')
                proc.stdin.end()

    ###*
     * @param {String} rawOutput
     * @param {Array}  parameters
    ###
    showUnexpectedOutputError: (rawOutput, parameters) ->
        atom.notifications.addError('php-integrator - Oops, something went wrong!', {
            dismissable : true
            detail      :
                "PHP sent back something unexpected. This is most likely an issue with your setup. If you're sure " +
                "this is a bug, feel free to report it on the bug tracker." +
                "\n \nCommand\n  → " + parameters.join(' ') +
                "\n \nOutput\n  → " + rawOutput
        })

    ###*
     * Performs a request to the PHP side.
     *
     * @param {Array}    args           The arguments to pass.
     * @param {Callback} streamCallback A method to invoke each time streaming data is received.
     * @param {String}   stdinData      The data to pass to STDIN.
     *
     * @todo Support stdinData for synchronous requests as well.
     *
     * @return {Promise}
    ###
    performRequest: (args, streamCallback = null, stdinData = null) ->
        php = @config.get('phpCommand')

        args.unshift(@projectName)

        parameters = @prepareParameters(args)

        if not @projectName
            return new Promise (resolve, reject) ->
                reject('Request aborted as there is no project active (yet)')

        return @performRequestAsync(php, parameters, streamCallback, stdinData)

    ###*
     * Retrieves a list of available classes.
     *
     * @return {Promise}
    ###
    getClassList: () ->
        parameters = [
            '--class-list',
            '--database=' + @getIndexDatabasePath()
        ]

        return @performRequest(parameters)

    ###*
     * Retrieves a list of available classes in the specified file.
     *
     * @param {String} file
     *
     * @return {Promise}
    ###
    getClassListForFile: (file) ->
        if not file
            return new Promise (resolve, reject) ->
                reject('No file passed!')

        parameters = [
            '--class-list',
            '--database=' + @getIndexDatabasePath(),
            '--file=' + file
        ]

        return @performRequest(parameters)

    ###*
     * Retrieves a list of namespaces.
     *
     * @return {Promise}
    ###
    getNamespaceList: () ->
        parameters = [
            '--namespace-list',
            '--database=' + @getIndexDatabasePath()
        ]

        return @performRequest(parameters)

    ###*
     * Retrieves a list of namespaces in the specified file.
     *
     * @param {String} file
     *
     * @return {Promise}
    ###
    getNamespaceListForFile: (file) ->
        if not file
            return new Promise (resolve, reject) ->
                reject('No file passed!')

        parameters = [
            '--namespace-list',
            '--database=' + @getIndexDatabasePath(),
            '--file=' + file
        ]

        return @performRequest(parameters)

    ###*
     * Retrieves a list of available global constants.
     *
     * @return {Promise}
    ###
    getGlobalConstants: () ->
        parameters = [
            '--constants',
            '--database=' + @getIndexDatabasePath()
        ]

        return @performRequest(parameters)

    ###*
     * Retrieves a list of available global functions.
     *
     * @return {Promise}
    ###
    getGlobalFunctions: () ->
        parameters = [
            '--functions',
            '--database=' + @getIndexDatabasePath()
        ]

        return @performRequest(parameters)

    ###*
     * Retrieves a list of available members of the class (or interface, trait, ...) with the specified name.
     *
     * @param {String} className
     *
     * @return {Promise}
    ###
    getClassInfo: (className) ->
        if not className
            return new Promise (resolve, reject) ->
                reject('No class name passed!')

        parameters = [
            '--class-info',
            '--database=' + @getIndexDatabasePath(),
            '--name=' + className
        ]

        return @performRequest(parameters)

    ###*
     * Resolves a local type in the specified file, based on use statements and the namespace.
     *
     * @param {String}  file
     * @param {Number}  line The line the type is located at. The first line is 1, not 0.
     * @param {String}  type
     *
     * @return {Promise}
    ###
    resolveType: (file, line, type) ->
        if not file
            return new Promise (resolve, reject) ->
                reject('No file passed!')

        if not line
            return new Promise (resolve, reject) ->
                reject('No line passed!')

        if not type
            return new Promise (resolve, reject) ->
                reject('No type passed!')

        parameters = [
            '--resolve-type',
            '--database=' + @getIndexDatabasePath(),
            '--file=' + file,
            '--line=' + line,
            '--type=' + type
        ]

        return @performRequest(parameters)

    ###*
     * Localizes a type to the specified file, making it relative to local use statements, if possible. If not possible,
     * null is returned.
     *
     * @param {String}  file
     * @param {Number}  line The line the type is located at. The first line is 1, not 0.
     * @param {String}  type
     *
     * @return {Promise}
    ###
    localizeType: (file, line, type) ->
        if not file
            return new Promise (resolve, reject) ->
                reject('No file passed!')

        if not line
            return new Promise (resolve, reject) ->
                reject('No line passed!')

        if not type
            return new Promise (resolve, reject) ->
                reject('No type passed!')

        parameters = [
            '--localize-type',
            '--database=' + @getIndexDatabasePath(),
            '--file=' + file,
            '--line=' + line,
            '--type=' + type
        ]

        return @performRequest(parameters)

    ###*
     * Performs a semantic lint of the specified file.
     *
     * @param {String}      file
     * @param {String|null} source  The source code of the file to index. May be null if a directory is passed instead.
     * @param {Object}      options Additional options to set. Boolean properties noUnknownClasses, noUnknownMembers,
     *                              noUnknownGlobalFunctions, noUnknownGlobalConstants, noDocblockCorrectness and
     *                              noUnusedUseStatements are supported.
     *
     * @return {Promise}
    ###
    semanticLint: (file, source, options = {}) ->
        if not file
            return new Promise (resolve, reject) ->
                reject('No file passed!')

        parameters = [
            '--semantic-lint',
            '--database=' + @getIndexDatabasePath(),
            '--file=' + file,
            '--stdin'
        ]

        if options.noUnknownClasses == true
            parameters.push('--no-unknown-classes')

        if options.noUnknownMembers == true
            parameters.push('--no-unknown-members')

        if options.noUnknownGlobalFunctions == true
            parameters.push('--no-unknown-global-functions')

        if options.noUnknownGlobalConstants == true
            parameters.push('--no-unknown-global-constants')

        if options.noDocblockCorrectness == true
            parameters.push('--no-docblock-correctness')

        if options.noUnusedUseStatements == true
            parameters.push('--no-unused-use-statements')

        return @performRequest(
            parameters,
            null,
            source
        )

    ###*
     * Fetches all available variables at a specific location.
     *
     * @param {String|null} file   The path to the file to examine. May be null if the source parameter is passed.
     * @param {String|null} source The source code to search. May be null if a file is passed instead.
     * @param {Number}      offset The character offset into the file to examine.
     *
     * @return {Promise}
    ###
    getAvailableVariables: (file, source, offset) ->
        if not file? and not source?
            return new Promise (resolve, reject) ->
                reject('Either a path to a file or source code must be passed!')

        if file?
            parameter = '--file=' + file

        if source?
            parameter = '--stdin'

        parameters = [
            '--available-variables',
            '--database=' + @getIndexDatabasePath(),
            parameter,
            '--offset=' + offset,
            '--charoffset'
        ]

        return @performRequest(parameters, null, source)

    ###*
     * Fetches the types of the specified variable at the specified location.
     *
     * @deprecated Use deduceTypes instead.
     *
     * @param {String}      name   The variable to fetch, including its leading dollar sign.
     * @param {String}      file   The path to the file to examine.
     * @param {String|null} source The source code to search. May be null if a file is passed instead.
     * @param {Number}      offset The character offset into the file to examine.
     *
     * @return {Promise}
    ###
    getVariableTypes: (name, file, source, offset) ->
        return @deduceTypes([name], file, source, offset)

    ###*
     * Deduces the resulting types of an expression based on its parts.
     *
     * @param {Array|null}  parts             One or more strings that are part of the expression, e.g.
     *                                        ['$this', 'foo()']. If null, the expression will automatically be deduced
     *                                        based on the offset.
     * @param {String}      file              The path to the file to examine.
     * @param {String|null} source            The source code to search. May be null if a file is passed instead.
     * @param {Number}      offset            The character offset into the file to examine.
     * @param {bool}        ignoreLastElement Whether to remove the last element or not, this is useful when the user
     *                                        is still writing code, e.g. "$this->foo()->b" would normally return the
     *                                        type (class) of 'b', as it is the last element, but as the user is still
     *                                        writing code, you may instead be interested in the type of 'foo()'
     *                                        instead.
     *
     * @return {Promise}
    ###
    deduceTypes: (parts, file, source, offset, ignoreLastElement) ->
        if not file?
            return new Promise (resolve, reject) ->
                reject('A path to a file must be passed!')

        parameters = [
            '--deduce-types',
            '--database=' + @getIndexDatabasePath(),
            '--offset=' + offset,
            '--charoffset'
        ]

        if file?
            parameters.push('--file=' + file)

        if source?
            parameters.push('--stdin')

        if ignoreLastElement
            parameters.push('--ignore-last-element')

        if parts?
            for part in parts
                parameters.push('--part=' + part)

        return @performRequest(
            parameters,
            null,
            source
        )

    ###*
     * Fetches invocation information of a method or function call.
     *
     * @param {String|null} file   The path to the file to examine. May be null if the source parameter is passed.
     * @param {String|null} source The source code to search. May be null if a file is passed instead.
     * @param {Number}      offset The character offset into the file to examine.
     *
     * @return {Promise}
    ###
    getInvocationInfo: (file, source, offset) ->
        if not file? and not source?
            return new Promise (resolve, reject) ->
                reject('Either a path to a file or source code must be passed!')

        if file?
            parameter = '--file=' + file

        if source?
            parameter = '--stdin'

        parameters = [
            '--invocation-info',
            '--database=' + @getIndexDatabasePath(),
            parameter,
            '--offset=' + offset,
            '--charoffset'
        ]

        return @performRequest(parameters, null, source)

    ###*
     * Truncates the database.
     *
     * @return {Promise}
    ###
    truncate: () ->
        parameters = [
            '--truncate',
            '--database=' + @getIndexDatabasePath()
        ]

        return @performRequest(parameters, null, null)

    ###*
     * Initializes a project.
     *
     * @return {Promise}
    ###
    initialize: () ->
        parameters = [
            '--initialize',
            '--database=' + @getIndexDatabasePath()
        ]

        return @performRequest(parameters, null, null)

    ###*
     * Vacuums a project, cleaning up the index database (e.g. pruning files that no longer exist).
     *
     * @return {Promise}
    ###
    vacuum: () ->
        parameters = [
            '--vacuum',
            '--database=' + @getIndexDatabasePath()
        ]

        return @performRequest(parameters, null, null)

    ###*
     * Refreshes the specified file or folder. This method is asynchronous and will return immediately.
     *
     * @param {String|Array}  path                   The full path to the file  or folder to refresh. Alternatively,
     *                                              this can be a list of items to index at the same time.
     * @param {String|null}   source                 The source code of the file to index. May be null if a directory is
     *                                              passed instead.
     * @param {Callback|null} progressStreamCallback A method to invoke each time progress streaming data is received.
     * @param {Array}         excludedPaths          A list of paths to exclude from indexing.
     * @param {Array}         fileExtensionsToIndex  A list of file extensions (without leading dot) to index.
     *
     * @return {Promise}
    ###
    reindex: (path, source, progressStreamCallback, excludedPaths, fileExtensionsToIndex) ->
        if typeof path == "string"
            pathsToIndex = []

            if path
                pathsToIndex.push(path)

        else
            pathsToIndex = path

        if path.length == 0
            return new Promise (resolve, reject) ->
                reject('No filename passed!')

        progressStreamCallbackWrapper = null

        parameters = [
            '--reindex',
            '--database=' + @getIndexDatabasePath()
        ]

        if progressStreamCallback?
            parameters.push('--stream-progress')

            progressStreamCallbackWrapper = (output) =>
                # Sometimes we receive multiple lines in bulk, so we must ensure it remains split correctly.
                percentages = output.toString('ascii').split("\n")
                percentages.pop() # Ditch the empty value.

                for percentage in percentages
                    progressStreamCallback(percentage)

        for pathToIndex in pathsToIndex
            parameters.push('--source=' + pathToIndex)

        if source?
            parameters.push('--stdin')

        for excludedPath in excludedPaths
            parameters.push('--exclude=' + excludedPath)

        for fileExtensionToIndex in fileExtensionsToIndex
            parameters.push('--extension=' + fileExtensionToIndex)

        return @performRequest(
            parameters,
            progressStreamCallbackWrapper,
            source
        )

    ###*
     * Sets the name (without path or extension) of the database file to use.
     *
     * @param {String} name
    ###
    setIndexDatabaseName: (name) ->
        @indexDatabaseName = name

    ###*
     * Sets the project name to pass.
     *
     * @param {String} name
    ###
    setProjectName: (name) ->
        @projectName = name

    ###*
     * Retrieves the full path to the database file to use.
     *
     * @return {String}
    ###
    getIndexDatabasePath: () ->
        return @config.get('packagePath') + '/indexes/' + @indexDatabaseName + '.sqlite'
