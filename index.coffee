{ObjectID, MongoClient} = require 'mongodb'
{EventEmitter} = require 'events'
{en: lingo} = require 'lingo'
_ = require 'underscore'

class Model
  @initialize: (options) ->
    _.extend @, options,
      _collection: null
      _queued_operators: []

  # create document, callback
  # create document, options, callback
  # document: document or documents
  # callback.this: model
  @create: ->
    @execute('insert') @injectCallback arguments, (err, documents) ->
      @callback err, documents?[0]

  # count query, callback
  # count query, options, callback
  # count callback
  # callback.this: model
  @count: ->
    @execute('count') @injectCallback arguments

  # find query, callback
  # find query, options, callback
  # find callback
  # callback.this: model
  @find: ->
    self = @

    @execute('find') @injectCallback arguments, (err, cursor) ->
      return @callback err if err

      cursor.toArray (err, documents) =>
        @callback err, self.buildDocument documents

  # findOne query, callback
  # findOne query, options, callback
  # findOne callback
  # callback.this: model
  @findOne: ->
    @execute('findOne') @injectCallback arguments

  # findById id, callback
  # findById id, options, callback
  # findById callback
  # callback.this: model
  @findById: (id) ->
    try
      arguments[0] = _id: ObjectID id
      @findOne.apply @, arguments
    catch err
      callback = _.last arguments
      callback err if _.isFunction callback

  # findOneAndUpdate query, update, options, callback
  # findOneAndUpdate query, update, callback
  # options.sort
  # options.new: default to true
  # callback.this: model
  @findOneAndUpdate: (query, update, options, _callback) ->
    self = @

    callback = _.last @injectCallback arguments, (err, document) ->
      @callback err, self.buildDocument document

    unless _callback
      options = {new: true, sort: []}

    @execute('findAndModify') [query, options.sort, update, options, callback]

  # findByIdAndUpdate id, update, options, callback
  # findByIdAndUpdate id, update, callback
  # options.new: default to true
  # callback.this: model
  @findByIdAndUpdate: (id) ->
    try
      arguments[0] = _id: ObjectID id
      @findOneAndUpdate.apply @, arguments
    catch err
      callback = _.last arguments
      callback err if _.isFunction callback

  # findOneAndRemove query, options, callback
  # findOneAndRemove query, callback
  # options.sort
  # callback.this: model
  @findOneAndRemove: (query, options, _callback) ->
    self = @

    callback = _.last @injectCallback arguments, (err, document) ->
      @callback err, self.buildDocument document

    unless _callback
      options = {sort: []}

    @execute('findAndRemove') [query, options.sort, options, callback]

  # findByIdAndRemove id, options, callback
  # findByIdAndRemove id, callback
  # options.sort
  # callback.this: model
  @findByIdAndRemove: (id) ->
    try
      arguments[0] = _id: ObjectID id
      @findOneAndRemove.apply @, arguments
    catch err
      callback = _.last arguments
      callback err if _.isFunction callback

  # update query, updates, callback
  # update query, updates, options, callback
  # callback.this: model
  @update: ->
    @execute('update') arguments

  # remove query, callback
  # remove query, options, callback
  # callback.this: model
  @remove: ->
    @execute('remove') arguments

  # private
  @injectCallback: (args, callback) ->
    args = _.toArray args
    original = args[args.length - 1]
    self = @

    callback ?= ->
      @callback.apply @, arguments

    if _.isFunction original
      next = ->
        callback.apply
          callback: ->
            original.apply self, arguments
        , arguments

      args[args.length - 1] = (err, document) =>
        next err, @buildDocument document

    return args

  # private
  @execute: (name) ->
    if @_collection
      return (args) =>
        @_collection[name].apply @_collection, args
    else
      return (args) =>
        @_queued_operators.push =>
          @_collection[name].apply @_collection, args

  @getCollection: ->
    return @_mabolo.db?.collection @_options.collection_name

  # private
  @runQueuedOperators: ->
    @_collection = @getCollection()
    until _.isEmpty @_queued_operators
      @_queued_operators.shift()()

  # buildDocument document
  # buildDocument documents
  @buildDocument: (document) ->
    if document?.cursorId?._bsontype
      return document

    else if _.isArray document
      return _.map document, (doc) =>
        return new @ doc

    else if _.isObject document
      return new @ document

    else
      return document

  _isNew: false
  _isRemoved: false

  constructor: (document) ->
    unless document._id
      @_isNew = true

    _.extend @, document

  toObject: ->
    props = _.without.apply @, [Object.getOwnPropertyNames @].concat ['_isNew', '_isRemoved']
    return _.pick.apply @, [@].concat props

  # update update, options, callback
  # update update, callback
  # options.new: default to true
  # callback.this: document
  update: (update, options, callback) ->
    args = _.toArray arguments
    args.unshift @_id

    original = _.last args
    args[args.length - 1] = (err, document) =>
      unless options.new == false
        _.extend @, document

      original.apply @, arguments

    @constructor.findByIdAndUpdate.apply @constructor, args

  # callback.this: document
  save: (_callback) ->
    model = @constructor

    if !@_isNew and @_isRemoved
      throw new Error 'Currently only supports new document'

    callback = (err, documents) =>
      document = documents?[0]

      if document
        _.extend @, document

      _callback.apply @, [err, model.buildDocument document?[0]]

    model.execute('insert') [@toObject(), callback]

  validate: (callback) ->
    callback()

  remove: (callback) ->
    @_isRemoved = true

    @constructor.remove _id: @_id, ->
      callback.apply null, arguments

module.exports = class Mabolo extends EventEmitter
  db: null
  models: {}

  # uri: optional mongodb uri, if provided will automatically call `Mabolo.connect`
  constructor: (uri) ->
    if uri
      @connect uri

  connect: (uri, callback = ->) ->
    MongoClient.connect uri, (err, db) =>
      if err
        if @listeners 'error'
          @emit 'error', err
        else
          throw err

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
