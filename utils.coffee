{ObjectID} = require 'mongodb'
crypto = require 'crypto'
_ = require 'underscore'

exports.pass = pass = ->

exports.dotGet = dotGet = (object, path) ->
  paths = path.split '.'
  ref = object

  for key in paths
    if ref[key] == undefined
      return undefined
    else
      ref = ref[key]

  return ref

exports.dotSet = dotSet = (object, path, value) ->
  paths = path.split '.'
  last_path = paths.pop()
  ref = object

  for key in paths
    ref[key] ?= {}
    ref = ref[key]

  ref[last_path] = value

exports.dotPick = (object, keys) ->
  result = {}

  for key in keys
    if dotGet(object, key) != undefined
      dotSet result, key, dotGet(object, key)

  return result

exports.randomVersion = randomVersion = ->
  return crypto.pseudoRandomBytes(4).toString 'hex'

exports.isModel = isModel = (value) ->
  return value?._schema

exports.isDocument = (value) ->
  return isModel value?.constructor

exports.isEmbeddedDocument = (value) ->
  return value?._path and !value._index

exports.isEmbeddedArray = (value) ->
  return value?._path and value._index

exports.isInstanceOf = (Type, value) ->
  switch Type
    when String
      return _.isString value

    when Number
      return _.isNumber value

    when Date
      return _.isDate value

    when Boolean
      return _.isBoolean value

    else
      return value instanceof Type

exports.forEachPath = (model, document, iterator) ->
  for path, definition of model._schema
    value = dotGet document, path

    if definition.type
      Type = definition.type
    else if _.isFunction definition
      Type = definition
    else
      Type = null

    it =
      Type: Type

      dotSet: (value) ->
        dotSet document, path, value

      isEmbeddedArrayPath: ->
        return _.isArray definition

      getEmbeddedArrayModel: ->
        return _.first definition

      isEmbeddedDocumentPath: ->
        return isModel Type

      getEmbeddedDocumentModel: ->
        return Type

    iterator path, value, definition, it

exports.addVersionForUpdates = (updates) ->
  is_atom_op = _.every _.keys(updates), (key) ->
    return key[0] == '$'

  if is_atom_op
    updates.$set ?= {}
    updates.$set['__v'] ?= randomVersion()
  else
    updates['__v'] ?= randomVersion()

exports.addPrefixForUpdates = addPrefixForUpdates = (updates, document) ->
  paths = []

  for k, v of updates
    if k[0] == '$'
      if _.isObject(v) and !_.isArray(v)
        addPrefixForUpdates v, document

    else
      paths.push k

  if document._index
    prefix = "#{document._path}.$."
  else
    prefix = "#{document._path}."

  for k in paths
    updates[prefix + k] = updates[k]
    delete updates[k]

exports.formatValidators = (validators) ->
  if _.isFunction validators
    validators = [validators]

  else if !_.isArray(validators) and _.isObject(validators)
    validators = _.map validators, (validator, name) ->
      validator.validator_name = name
      return validator

  return validators
