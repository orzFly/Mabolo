{ObjectID, MongoClient} = require 'mongodb'
{EventEmitter} = require 'events'
{en: lingo} = require 'lingo'
async = require 'async'
_ = require 'underscore'

{extend, isEmpty} = _

{pass, dotGet, dotSet, dotPick, randomVersion, addVersionForUpdates} = require './utils'
{formatValidators, isTypeOf, isModel, isEmbedded, isEmbeddedDocument} = require './utils'
{isEmbeddedArray} = require './utils'

class Model
  @initialize: (options) ->
    extend @, options,
      _collection: null
      _queued_operators: []

    if @getCollection()
      @runQueuedOperators()

  @execute: (name) ->
    collection = @_collection
    queued_operators = @_queued_operators

    if collection
      return ->
        collection[name].apply collection, arguments
    else
      return ->
        queued_operators.push ->
          collection[name].apply collection, arguments

  @runQueuedOperators: ->
    if @_queue_started
      return

    extend @,
      _queue_started: true
      _collection: @getCollection()

    until isEmpty @_queued_operators
      @_queued_operators.shift()()

  @injectCallback: (args, callback) ->
    args = _.toArray args
    _callback = args[args.length - 1]
    self = @

    callback ?= ->
      @callback.apply @, arguments

    if _.isFunction _callback
      next = ->
        callback.apply
          callback: ->
            _callback.apply self, arguments
        , arguments

      args[args.length - 1] = (err, document) =>
        next err, @transform document

    return args

  @getCollection: ->
    return @_mabolo.db?.collection @_options.collection_name

  @transform: (document) ->
    if document?.cursorId?._bsontype
      return document

    else if _.isArray document
      return _.map document, (doc) =>
        return new @ doc

    else if _.isObject document
      return new @ document

    else
      return document

  @create: (document, callback) ->
    document = new @ document

    document.save (err) ->
      callback.call document, err, document

  @ensureIndex: ->
    @execute('ensureIndex').apply null, arguments

  @aggregate: ->
    @execute('aggregate').apply null, arguments

  @count: ->
    @execute('count').apply null, @injectCallback arguments

  @find: ->
    self = @

    @execute('find').apply null, @injectCallback arguments, (err, cursor) ->
      if err
        @callback err
      else
        cursor.toArray (err, documents) =>
          @callback err, self.transform documents

  @findOne: ->
    @execute('findOne').apply null, @injectCallback arguments

  @findById: (id) ->
    try
      arguments[0] = _id: ObjectID id
      @findOne.apply @, arguments
    catch err
      (_.last arguments) err

  @findOneAndUpdate: (query, updates, options, _callback) ->
    addVersionForUpdates updates
    self = @

    callback = _.last @injectCallback arguments, (err, document) ->
      @callback err, self.transform document

    unless _callback
      options =
        new: true
        sort: null

    @execute('findAndModify') query, options.sort, updates, options, callback

  @findByIdAndUpdate: (id) ->
    try
      arguments[0] = _id: ObjectID id
      @findOneAndUpdate.apply @, arguments
    catch err
      (_.last arguments) err

  @findOneAndRemove: (query, options, _callback) ->
    self = @

    callback = _.last @injectCallback arguments, (err, document) ->
      @callback err, self.transform document

    unless _callback
      options =
        sort: null

    @execute('findAndRemove') query, options.sort, options, callback

  @findByIdAndRemove: (id) ->
    try
      arguments[0] = _id: ObjectID id
      @findOneAndRemove.apply @, arguments
    catch err
      (_.last arguments) err

  @update: (query, updates) ->
    addVersionForUpdates updates
    @execute('update').apply null, arguments

  @remove: ->
    @execute('remove').apply null, arguments

  constructor: (document) ->
    Object.defineProperties @,
      _isNew:
        writable: true
      _isRemoved:
        writable: true
      _parent:
        writable: true
      _path:
        writable: true
      _index:
        writable: true
      __v:
        writable: true

    _.extend @, document

    unless @_id
      @_isNew = true

      if @_parent
        @_id = ObjectID()

    unless @__v
      @__v = randomVersion()

    @buildSubDocuments()

  buildSubDocuments: ->
    model = @constructor
    schema = model._schema

    for path, definition of schema
      value = dotGet @, path

      if _.isArray definition
        if value == undefined
          dotSet @, path, []
          continue

        SubModel = _.first definition

        unless SubModel._schema
          continue

        dotSet @, path, _.map value, (value, index) =>
          if value._path
            return value

          return sud_document = new SubModel _.extend value,
            _parent: @
            _path: path
            _index: index

      else if definition.type?._schema
        unless _.isObject value
          continue

        if value?._path
          continue

        SubModel = definition.type

        dotSet @, path, new SubModel _.extend value,
          _parent: @
          _path: path

  # return: Model
  parent: ->
    return @_parent

  # return: object
  toObject: ->
    result = _.pick.apply @, [@].concat Object.keys @

    for path, definition of @constructor._schema
      if _.isArray definition
        if _.first(definition)._schema
          dotSet result, path, _.map dotGet(result, path), (item) ->
            return item.toObject()

      else if definition.type?._schema
        value = dotGet(result, path)

        if value?.toObject
          dotSet result, path, value.toObject()

    return result

  # update updates, options, callback
  # update updates, callback
  # options.new: default to true
  # callback(err)
  # callback.this: document
  update: (updates, options, callback) ->
    # TODO: sub-Model
    args = _.toArray arguments
    args.unshift @_id

    original = _.last args
    args[args.length - 1] = (err, document) =>
      unless options.new == false
        _.extend @, document

      original.apply @, arguments

    @constructor.findByIdAndUpdate.apply @constructor, args

  # callback(err)
  # callback.this: document
  save: (_callback) ->
    model = @constructor

    if !@_isNew and @_isRemoved
      throw new Error 'Cant save exists document'

    if @_parent
      throw new Error 'Cant save sub-document'

    for path, definition of model._schema
      {default: default_value} = definition

      if dotGet(@, path) == undefined and default_value != undefined
        if _.isFunction default_value
          default_value = default_value()
        else
          default_value = _.clone default_value

        dotSet @, path, default_value

    document = dotPick @, _.keys(model._schema)
    document.__v = @__v

    @validate (err) ->
      return _callback err if err

      callback = (err, documents) =>
        document = documents?[0]

        if document
          _.extend @, document

        _callback.call @, err

      model.execute('insert').apply @, [document, callback]

  # modifier(commit(err))
  # modifier.this: document
  # callback(err)
  # callback.this: document
  modify: (modifier, callback) ->
    # TODO: sub-Model
    model = @constructor
    FINISHED = {}

    unless @_id
      throw new Error 'Document not yet exists in MongoDB'

    overwrite = (latest) =>
      for key in _.keys model._schema
        delete @[key]

      _.extend @, latest
      @__v = latest.__v

    rollback = (callback) =>
      model.findById @_id, (err, result) =>
        overwrite result
        callback()

    async.forever (next) =>
      modifier.call @, (err) =>
        if err
          return rollback ->
            next err

        @validate (err) ->
          if err
            return rollback ->
              next err

          original_v = @__v
          @__v = randomVersion()
          document = dotPick @, _.keys(model._schema)

          model.findOneAndUpdate
            _id: @_id
            __v: original_v
          , document, (err, result) =>
            if err
              rollback ->
                next err

            else if result
              next FINISHED

            else
              rollback next

    , (err) =>
      err = null if err == FINISHED
      callback.apply @, [err]

  # callback(err)
  # callback.this: document
  validate: (callback) ->
    @buildSubDocuments()

    error = (path, type, message) =>
      callback.apply @, [new Error "validating fail when `#{path}` #{type} #{message}"]

    sub_documents = []
    async_validators = []

    # Built-in
    for path, definition of @constructor._schema
      value = dotGet @, path

      if value == undefined and !definition.required
        continue

      typeError = (message) ->
        error path, 'type', message

      if _.isArray definition
        Type = _.first definition

        for item in value
          if Type._schema
            unless item instanceof Type
              return typeError 'is array of ' + Type._name

            sub_documents.push item

          else
            err = isTypeOf Type, item
            return typeError err if err

      if definition.type
        if definition.type._schema
          if value
            unless value instanceof definition.type
              return typeError 'is ' + definition.type._name

            sub_documents.push value

          else if definition.required
            return typeError 'is ' + definition.type._name

        else
          err = isTypeOf definition.type, value
          return typeError err if err

      if definition.enum
        unless value in definition.enum
          return error path, 'enum', "in [#{definition.enum.join ', '}]"

      if definition.regex
        unless definition.regex.test value
          return error path, 'regex', "match #{definition.regex}"

      # sync validator
      if definition.validator
        validators = formatValidators definition.validator

        sync_validators = _.filter validators, (validator) ->
          return validator.length != 2

        for validator in sync_validators
          unless validator.apply @, [value]
            return error path, 'validator(sync)', validator.validator_name

        async_validators = async_validators.concat _.filter validators, (validator) ->
          unless validator.length == 2
            return false

          return _.extend validator,
            value: value
            path: path

    async.parallel [
      # sub-Model
      (callback) ->
        async.each sub_documents, (sub_document, callback) ->
          sub_document.validate callback
        , callback

      # async validator
      (callback) ->
        async.each async_validators, (validator, callback) ->
          validator validator.value, (err) ->
            if err
              err = new Error "validating fail when `#{path}` validator(async) #{err}"

            callback err

        , callback

    ], (err) =>
      callback.call @, err

  # callback(err, result)
  remove: (callback) ->
    # TODO: sub-Model
    @_isRemoved = true

    @constructor.remove _id: @_id, ->
      callback.apply null, arguments

module.exports = class Mabolo extends EventEmitter
  db: null
  models: {}

  ObjectID: ObjectID

  # uri: if provided will automatically call `Mabolo.connect`
  constructor: (uri) ->
    if uri
      @connect uri

  # uri: optional mongodb uri
  # callback(err, db)
  connect: (uri, callback = ->) ->
    MongoClient.connect uri, (err, db) =>
      if err
        @emit 'error', err

      else
        @db = db
        @emit 'connected', db

      callback err, db

  # name: a camelcase model name, like `Account`
  # schema: schema definition object
  # options.collection_name: overwrite default collection name
  model: (name, schema, options) ->
    options = _.extend(
      collection_name: lingo.pluralize name.toLowerCase()
    , options)

    class model extends Model

    model.initialize
      _mabolo: @
      _name: name
      _schema: schema
      _options: options
      methods: model.prototype

    @models[name] = model

    @on 'connected', ->
      model.runQueuedOperators()

    return model
