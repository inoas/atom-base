fs            = require 'fs'
net           = require 'net'
stream        = require 'stream'
child_process = require 'child_process'

module.exports =

##*
# Proxy that handles communicating with the PHP side.
##
class Proxy
    ###*
     * The config to use.
     *
     * @var {Object}
    ###
    config: null

    ###*
     * The name (without path or extension) of the database file to use.
     *
     * @var {Object}
    ###
    indexDatabaseName: null

    ###*
     * @var {Object}
    ###
    phpServer: null

    ###*
     * @var {Promise}
    ###
    phpServerPromise: null

    ###*
     * @var {Object}
    ###
    client: null

    ###*
     * @var {Object}
    ###
    requestQueue: null

    ###*
     * @var {Number}
    ###
    nextRequestId: 1

    ###*
     * @var {Object}
    ###
    response: null

    ###*
     * @var {String}
    ###
    HEADER_DELIMITER: "\r\n"

    ###*
     * @var {Number}
    ###
    FATAL_SERVER_ERROR: -32000

    ###*
     * Constructor.
     *
     * @param {Config} config
    ###
    constructor: (@config) ->
        @requestQueue = {}
        @port = @getRandomServerPort()

        @resetResponseState()

    ###*
     * Spawns the PHP socket server process.
     *
     * @param {Number} port
     *
     * @return {Promise}
    ###
    spawnPhpServer: (port) ->
        php = @config.get('phpCommand')
        memoryLimit = @config.get('memoryLimit')

        parameters = [
             '-d memory_limit=' + memoryLimit + 'M',
             @getCorePackagePath() + "/src/Main.php",
             '--port=' + port
        ]

        process = child_process.spawn(php, parameters)

        return new Promise (resolve, reject) =>
            process.stdout.on 'data', (data) =>
                console.debug('The PHP server has something to say:', data.toString())

                # Assume the server has successfully spawned the moment it says its first words.
                resolve(process)

            process.stderr.on 'data', (data) =>
                console.warn('The PHP server has errors to report:', data.toString())

            process.on 'close', (code) =>
                if code == 2
                    console.error('Port ' + port + ' is already taken')
                    return

                console.warn('PHP socket server exited by itself, a fatal error must have occurred.')

    ###*
     * @return {Number}
    ###
    getRandomServerPort: () ->
        minPort = 10000
        maxPort = 40000

        return Math.floor(Math.random() * (maxPort - minPort) + minPort)

    ###*
     * Spawns the PHP socket server process.
     *
     * @param {Number} port
     *
     * @return {Promise}
    ###
    spawnPhpServerIfNecessary: (port) ->
        if @phpServer
            return new Promise (resolve, reject) =>
                resolve(@phpServer)

        else if @phpServerPromise
            return @phpServerPromise

        @phpServerPromise = @spawnPhpServer(port).then (phpServer) =>
            @phpServer = phpServer

            return phpServer

        return @phpServerPromise

    ###*
     * Sends the kill signal to the socket server.
     *
     * Note that this is a signal, the process may ignore it (but it usually will not, unless it's really persistent in
     * continuing whatever it's doing).
     *
     * @param {Array} parameters
     *
     * @return {Array}
    ###
    stopPhpServer: (port) ->
        if @client
            @client.destroy()

        return if not @phpServer

        @phpServer.kill()
        @phpServer = null

    ###*
     * @return {String}
    ###
    getCorePackagePath: () ->
        return atom.packages.resolvePackagePath("php-integrator-core")

    ###*
     * @return {Object}
    ###
    getSocketConnection: () ->
        return new Promise (resolve, reject) =>
            @spawnPhpServerIfNecessary(@port).then () =>
                if @client?
                    resolve(@client)
                    return

                @client = net.createConnection {port: @port}, () =>
                    resolve(@client)

                @client.setNoDelay(true)
                @client.on('data', @onDataReceived.bind(this))
                @client.on('close', @onConnectionClosed.bind(this))

    ###*
     * @param {String} data
    ###
    onDataReceived: (data) ->
        try
            @processDataBuffer(data)

        catch error
            console.warn('Encountered some invalid data, resetting state. Error: ', error)

            @resetResponseState()

    ###*
     * @param {Boolean} hadError
    ###
    onConnectionClosed: (hadError) ->
        if hadError
            detail =
                "The socket connection with the PHP server could not be established. This means the PHP server could " +
                "not be spawned. This is most likely an issue with your setup, such as your PHP binary not being " +
                "found, an extension missing on your system, ..."

        else
            detail =
                "The socket connection to the PHP server was unexpectedly closed. Either something caused the process to " +
                "stop, the socket to close, or the PHP process may have crashed. If you're sure it's the last one, feel " +
                "free to report a bug.\n \n" +

                'An attempt will be made to restart the server and reestablish the connection.'

        atom.notifications.addError('PHP Integrator - Oops, something went wrong!', {
            dismissable : true
            detail      : detail
        })

        @client = null

    ###*
     * @param {Buffer} dataBuffer
    ###
    processDataBuffer: (dataBuffer) ->
        if not @response.length?
            contentLengthHeader = @readRawHeader(dataBuffer)
            @response.length = @getLengthFromContentLengthHeader(contentLengthHeader)

            bytesRead = contentLengthHeader.length + @HEADER_DELIMITER.length

        else if not @response.wasBoundaryFound
            header = @readRawHeader(dataBuffer)

            if header.length == 0
                @response.wasBoundaryFound = true

            bytesRead = header.length + @HEADER_DELIMITER.length

        else
            bytesRead = Math.min(dataBuffer.length, @response.length - @response.bytesRead)

            @response.content = Buffer.concat([@response.content, dataBuffer.slice(0, bytesRead)])
            @response.bytesRead += bytesRead

            if @response.bytesRead == @response.length
                jsonRpcResponse = @getJsonRpcResponseFromResponseBuffer(@response.content)

                @processJsonRpcResponse(jsonRpcResponse)

                @resetResponseState()

        dataBuffer = dataBuffer.slice(bytesRead)

        if dataBuffer.length > 0
            @processDataBuffer(dataBuffer)

    ###*
     * @param {Object} jsonRpcResponse
    ###
    processJsonRpcResponse: (jsonRpcResponse) ->
        if jsonRpcResponse.id?
            jsonRpcRequest = @requestQueue[jsonRpcResponse.id]

            @processJsonRpcResponseForRequest(jsonRpcResponse, jsonRpcRequest)

            delete @requestQueue[jsonRpcResponse.id]

        else
            @processNotificationJsonRpcResponse(jsonRpcResponse)

    ###*
     * @param {Object} jsonRpcResponse
     * @param {Object} jsonRpcRequest
    ###
    processJsonRpcResponseForRequest: (jsonRpcResponse, jsonRpcRequest) ->
        if jsonRpcResponse.error?
            jsonRpcRequest.promise.reject({
                request  : jsonRpcRequest
                response : jsonRpcResponse
                error    : jsonRpcResponse.error
            })

            if jsonRpcResponse.error.code == @FATAL_SERVER_ERROR
                @showUnexpectedSocketResponseError(jsonRpcResponse.error.message)

        else
            jsonRpcRequest.promise.resolve(jsonRpcResponse.result)

    ###*
     * @param {Object} jsonRpcResponse
     * @param {Object} jsonRpcRequest
    ###
    processNotificationJsonRpcResponse: (jsonRpcResponse) ->
        if not jsonRpcResponse.result?
            console.warn('Received a server notification without a result', jsonRpcResponse)
            return

        if jsonRpcResponse.result.type == 'reindexProgressInformation'
            if not jsonRpcResponse.result.requestId?
                console.warn('Received progress information without a request ID to go with it', jsonRpcResponse)
                return

            relatedJsonRpcRequest = @requestQueue[jsonRpcResponse.result.requestId]

            if not relatedJsonRpcRequest.streamCallback?
                console.warn('Received progress information for a request that isn\'t interested in it')
                return

            relatedJsonRpcRequest.streamCallback(jsonRpcResponse.result.progress)

        else
            console.warn('Received a server notification with an unknown type', jsonRpcResponse)

    ###*
     * @param {Buffer} dataBuffer
     *
     * @return {Object}
    ###
    getJsonRpcResponseFromResponseBuffer: (dataBuffer) ->
        jsonRpcResponseString = dataBuffer.toString()

        return @getJsonRpcResponseFromResponseContent(jsonRpcResponseString)

    ###*
     * @param {String} content
     *
     * @return {Object}
    ###
    getJsonRpcResponseFromResponseContent: (content) ->
        return JSON.parse(content)

    ###*
     * @param {Buffer} dataBuffer
     *
     * @throws {Error}
     *
     * @return {String}
    ###
    readRawHeader: (dataBuffer) ->
        end = dataBuffer.indexOf(@HEADER_DELIMITER)

        if end == -1
          throw new Error('Header delimiter not found');

        return dataBuffer.slice(0, end).toString()

    ###*
     * @param {String} rawHeader
     *
     * @throws {Error}
     *
     * @return {Number}
    ###
    getLengthFromContentLengthHeader: (rawHeader) ->
        parts = rawHeader.split(':')

        if parts.length != 2
            throw new Error('Unexpected amount of header parts found')

        contentLength = parseInt(parts[1])

        if not contentLength?
            throw new Error('Content length header does not have an integer as value')

        return contentLength

    ###*
     * Resets the current response's state.
    ###
    resetResponseState: () ->
        @response =
            length           : null
            wasBoundaryFound : false
            bytesRead        : 0
            content          : new Buffer([])

    ###*
     * Performs an asynchronous request to the PHP side.
     *
     * @param {Number}   id
     * @param {String}   method
     * @param {Object}   parameters
     * @param {Callback} streamCallback
     *
     * @return {Promise}
    ###
    performJsonRpcRequest: (id, method, parameters, streamCallback = null) ->
        return new Promise (resolve, reject) =>
            JsonRpcRequest =
                jsonrpc : 2.0
                id      : id
                method  : method
                params  : parameters

            @requestQueue[id] = {
                id             : id
                streamCallback : streamCallback
                request        : JsonRpcRequest

                promise: {
                    resolve : resolve
                    reject  : reject
                }
            }

            content = @getContentForJsonRpcRequest(JsonRpcRequest)

            @writeRawRequest(content)

    ###*
     * @param {Object} request
     *
     * @return {String}
    ###
    getContentForJsonRpcRequest: (request) ->
        return JSON.stringify(request)

    ###*
     * Writes a raw request to the connection.
     *
     * This may not happen immediately if the connection is not available yet. In that case, the request will be
     * dispatched as soon as the connection becomes available.
     *
     * @param {String} content The content (body) of the request.
    ###
    writeRawRequest: (content) ->
        @getSocketConnection().then (connection) =>
            lengthInBytes = (new TextEncoder('utf-8').encode(content)).length

            connection.write("Content-Length: " + lengthInBytes + @HEADER_DELIMITER)
            connection.write(@HEADER_DELIMITER);
            connection.write(content)

    ###*
     * @param {String}     rawOutput
     * @param {Array|null} parameters
    ###
    showUnexpectedSocketResponseError: (rawOutput, parameters = null) ->
        detail =
            "The socket server sent back something unexpected. This could be a bug, but it could also be a problem " +
            "with your setup. If you're sure it is a bug, feel free to report it on the bug tracker."

        if parameters?
            detail += "\n \nCommand\n  → " + parameters.join(' ')

        detail += "\n \nOutput\n  → " + rawOutput

        atom.notifications.addError('PHP Integrator - Oops, something went wrong!', {
            dismissable : true
            detail      : detail
        })

    ###*
     * @param {String}      method
     * @param {Object}      parameters
     * @param {Callback}    streamCallback A method to invoke each time streaming data is received.
     * @param {String|null} stdinData      The data to pass to STDIN.
     *
     * @return {Promise}
    ###
    performRequest: (method, parameters, streamCallback = null, stdinData = null) ->
        if not @getCorePackagePath()?
            return new Promise (resolve, reject) ->
                reject('''
                    The core package was not found, it is currently being installed. This only needs to happen once at
                    initialization, but the service is not available yet in the meantime.
                ''')
                return

        if stdinData?
            parameters.stdin = true
            parameters.stdinData = stdinData

        requestId = @nextRequestId++

        return @performJsonRpcRequest(requestId, method, parameters, streamCallback)

    ###*
     * Retrieves a list of available classes.
     *
     * @return {Promise}
    ###
    getClassList: () ->
        if not @getIndexDatabasePath()?
            return new Promise (resolve, reject) ->
                reject('Request aborted as there is no project active (yet)')

        parameters = {
            database : @getIndexDatabasePath()
        }

        return @performRequest('classList', parameters)

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

        if not @getIndexDatabasePath()?
            return new Promise (resolve, reject) ->
                reject('Request aborted as there is no project active (yet)')

        parameters = {
            database : @getIndexDatabasePath()
            file     : file
        }

        return @performRequest('classList', parameters)

    ###*
     * Retrieves a list of namespaces.
     *
     * @return {Promise}
    ###
    getNamespaceList: () ->
        if not @getIndexDatabasePath()?
            return new Promise (resolve, reject) ->
                reject('Request aborted as there is no project active (yet)')

        parameters = {
            database : @getIndexDatabasePath()
        }

        return @performRequest('namespaceList', parameters)

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

        if not @getIndexDatabasePath()?
            return new Promise (resolve, reject) ->
                reject('Request aborted as there is no project active (yet)')

        parameters = {
            database : @getIndexDatabasePath()
            file     : file
        }

        return @performRequest('namespaceList', parameters)

    ###*
     * Retrieves a list of available global constants.
     *
     * @return {Promise}
    ###
    getGlobalConstants: () ->
        if not @getIndexDatabasePath()?
            return new Promise (resolve, reject) ->
                reject('Request aborted as there is no project active (yet)')

        parameters = {
            database : @getIndexDatabasePath()
        }

        return @performRequest('globalConstants', parameters)

    ###*
     * Retrieves a list of available global functions.
     *
     * @return {Promise}
    ###
    getGlobalFunctions: () ->
        if not @getIndexDatabasePath()?
            return new Promise (resolve, reject) ->
                reject('Request aborted as there is no project active (yet)')

        parameters = {
            database : @getIndexDatabasePath()
        }

        return @performRequest('globalFunctions', parameters)

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

        if not @getIndexDatabasePath()?
            return new Promise (resolve, reject) ->
                reject('Request aborted as there is no project active (yet)')

        parameters = {
            database : @getIndexDatabasePath()
            name     : className
        }

        return @performRequest('classInfo', parameters)

    ###*
     * Resolves a local type in the specified file, based on use statements and the namespace.
     *
     * @param {String}  file
     * @param {Number}  line The line the type is located at. The first line is 1, not 0.
     * @param {String}  type
     * @param {String}  kind The kind of element. Either 'classlike', 'constant' or 'function'.
     *
     * @return {Promise}
    ###
    resolveType: (file, line, type, kind = 'classlike') ->
        if not file
            return new Promise (resolve, reject) ->
                reject('No file passed!')

        if not line
            return new Promise (resolve, reject) ->
                reject('No line passed!')

        if not type
            return new Promise (resolve, reject) ->
                reject('No type passed!')

        if not kind
            return new Promise (resolve, reject) ->
                reject('No kind passed!')

        if not @getIndexDatabasePath()?
            return new Promise (resolve, reject) ->
                reject('Request aborted as there is no project active (yet)')

        parameters = {
            database : @getIndexDatabasePath()
            file     : file
            line     : line
            type     : type
            kind     : kind
        }

        return @performRequest('resolveType', parameters)

    ###*
     * Localizes a type to the specified file, making it relative to local use statements, if possible. If not possible,
     * null is returned.
     *
     * @param {String}  file
     * @param {Number}  line The line the type is located at. The first line is 1, not 0.
     * @param {String}  type
     * @param {String}  kind The kind of element. Either 'classlike', 'constant' or 'function'.
     *
     * @return {Promise}
    ###
    localizeType: (file, line, type, kind = 'classlike') ->
        if not file
            return new Promise (resolve, reject) ->
                reject('No file passed!')

        if not line
            return new Promise (resolve, reject) ->
                reject('No line passed!')

        if not type
            return new Promise (resolve, reject) ->
                reject('No type passed!')

        if not kind
            return new Promise (resolve, reject) ->
                reject('No kind passed!')

        if not @getIndexDatabasePath()?
            return new Promise (resolve, reject) ->
                reject('Request aborted as there is no project active (yet)')

        parameters = {
            database : @getIndexDatabasePath()
            file     : file
            line     : line
            type     : type
            kind     : kind
        }

        return @performRequest('localizeType', parameters)

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

        if not @getIndexDatabasePath()?
            return new Promise (resolve, reject) ->
                reject('Request aborted as there is no project active (yet)')

        parameters = {
            database : @getIndexDatabasePath()
            file     : file
            stdin    : true
        }

        if options.noUnknownClasses == true
            parameters['no-unknown-classes'] = true

        if options.noUnknownMembers == true
            parameters['no-unknown-members'] = true

        if options.noUnknownGlobalFunctions == true
            parameters['no-unknown-global-functions'] = true

        if options.noUnknownGlobalConstants == true
            parameters['no-unknown-global-constants'] = true

        if options.noDocblockCorrectness == true
            parameters['no-docblock-correctness'] = true

        if options.noUnusedUseStatements == true
            parameters['no-unused-use-statements'] = true

        return @performRequest('semanticLint', parameters, null, source)

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

        if not @getIndexDatabasePath()?
            return new Promise (resolve, reject) ->
                reject('Request aborted as there is no project active (yet)')

        parameters = {
            database   : @getIndexDatabasePath()
            offset     : offset
            charoffset : true
        }

        if file?
            parameters.file = file

        return @performRequest('availableVariables', parameters, null, source)

    ###*
     * Deduces the resulting types of an expression.
     *
     * @param {String|null} expression        The expression to deduce the type of, e.g. '$this->foo()'. If null, the
     *                                        expression just before the specified offset will be used.
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
    deduceTypes: (expression, file, source, offset, ignoreLastElement) ->
        if not file?
            return new Promise (resolve, reject) ->
                reject('A path to a file must be passed!')

        if not @getIndexDatabasePath()?
            return new Promise (resolve, reject) ->
                reject('Request aborted as there is no project active (yet)')

        parameters = {
            database   : @getIndexDatabasePath()
            offset     : offset
            charoffset : true
        }

        if file?
            parameters.file = file

        if ignoreLastElement
            parameters['ignore-last-element'] = true

        if expression?
            parameters.expression = expression

        return @performRequest('deduceTypes', parameters, null, source)

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

        if not @getIndexDatabasePath()?
            return new Promise (resolve, reject) ->
                reject('Request aborted as there is no project active (yet)')

        parameters = {
            database   : @getIndexDatabasePath()
            offset     : offset
            charoffset : true
        }

        if file?
            parameters.file = file

        return @performRequest('invocationInfo', parameters, null, source)

    ###*
     * Initializes a project.
     *
     * @return {Promise}
    ###
    initialize: () ->
        if not @getIndexDatabasePath()?
            return new Promise (resolve, reject) ->
                reject('Request aborted as there is no project active (yet)')

        parameters = {
            database : @getIndexDatabasePath()
        }

        return @performRequest('initialize', parameters, null, null)

    ###*
     * Vacuums a project, cleaning up the index database (e.g. pruning files that no longer exist).
     *
     * @return {Promise}
    ###
    vacuum: () ->
        if not @getIndexDatabasePath()?
            return new Promise (resolve, reject) ->
                reject('Request aborted as there is no project active (yet)')

        parameters = {
            database : @getIndexDatabasePath()
        }

        return @performRequest('vacuum', parameters, null, null)

    ###*
     * Tests a project, to see if it is in a properly usable state.
     *
     * @return {Promise}
    ###
    test: () ->
        if not @getIndexDatabasePath()?
            return new Promise (resolve, reject) ->
                reject('Request aborted as there is no project active (yet)')

        parameters = {
            database : @getIndexDatabasePath()
        }

        return @performRequest('test', parameters, null, null)

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

        if not @getIndexDatabasePath()?
            return new Promise (resolve, reject) ->
                reject('Request aborted as there is no project active (yet)')

        progressStreamCallbackWrapper = null

        parameters = {
            database : @getIndexDatabasePath()
        }

        if progressStreamCallback?
            parameters['stream-progress'] = true

            progressStreamCallbackWrapper = progressStreamCallback

        parameters.source = pathsToIndex
        parameters.exclude = excludedPaths
        parameters.extension = fileExtensionsToIndex

        return @performRequest('reindex', parameters, progressStreamCallbackWrapper, source)

    ###*
     * Sets the name (without path or extension) of the database file to use.
     *
     * @param {String} name
    ###
    setIndexDatabaseName: (name) ->
        @indexDatabaseName = name

    ###*
     * Retrieves the full path to the database file to use.
     *
     * @return {String}
    ###
    getIndexDatabasePath: () ->
        return @config.get('packagePath') + '/indexes/' + @indexDatabaseName + '.sqlite'
