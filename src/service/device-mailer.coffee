fs                 = require 'fs'
_                  = require 'lodash'
nodemailer         = require 'nodemailer'
MeshbluHttp        = require 'meshblu-http'
MeshbluConfig      = require 'meshblu-config'

ChannelEncryption  = require '../models/channel-encryption'
ServiceDevice      = require '../models/service-device'
CredentialsDevice  = require '../models/credentials-device'
UserDevice         = require '../models/user-device'

class MailerService
  constructor: ({meshbluConfig, @serviceUrl}) ->
    throw new Error('serviceUrl is required in order for things to actually work') unless @serviceUrl?
    credentialsDeviceConfig = @_getCredentialsDeviceConfig {@serviceUrl}

    @userDeviceConfig       = @_getUserDeviceConfig {@serviceUrl}
    @channelEncryption      = new ChannelEncryption meshbluConfig
    @serviceDevice          = new ServiceDevice {meshbluConfig, credentialsDeviceConfig}

  onCreate: ({metadata}, callback) =>
    {auth} = metadata
    meshblu = new MeshbluHttp auth
    meshblu.register @userDeviceConfig, callback

  onConfig: ({metadata, config}, callback) =>
    {options, encryptedOptions, lastEncrypted} = config
    {auth} = metadata
    return callback() unless options?

    if lastEncrypted? && (Date.now() - lastEncrypted) < 1000
      return callback @_userError("Verification request detected within 1 second of last request", 403)

    userDevice = new UserDevice meshbluConfig: auth
    userDevice.setEncryptedOptions {options}, (error) =>
      console.log {options, error}
      return callback error if error?

      @getVerificationMessage {auth, options}, (error, message) =>
        return callback error if error?
        options =
          userDeviceUuid: config.uuid
          auth: auth
          options: options
          message: message

        @processMessage options, callback

  onReceived: ({metadata, message}, callback) =>
    {auth, forwardedFor, fromUuid} = metadata
    originalDevice = _.last forwardedFor

    credentialsDevice = new CredentialsDevice meshbluConfig: auth
    credentialsDevice.getClientSecret (error, clientSecret) =>
      return callback error if error?
      unless clientSecret?
        return meshblu.message {devices: [fromUuid], result: {error: 'encrypted options not found'}}, as: originalDevice, callback

      options =
        originalDevice: originalDevice
        fromUuid: fromUuid
        auth: auth
        options: clientSecret
        message: message

      @processMessage options, callback

  getVerificationMessage: ({auth, options}, callback) =>
    meshblu = new MeshbluHttp auth
    meshblu.generateAndStoreToken auth.uuid, (error, response) =>
      return callback error if error?
      code = encodeURIComponent(@channelEncryption.authToCode uuid: auth.uuid, token: response.token)

      message =
        to: options.auth.user
        from: options.auth.user
        subject: "Verify Email"
        text: "#{@serviceUrl}/device/verify?code=#{code}"

      callback null, message

  processMessage: ({originalDevice, auth, options, message, fromUuid}, callback) =>
    meshblu = new MeshbluHttp new MeshbluConfig(auth).toJSON()

    {transportOptions, transporter} = options
    if transporter
      transportOptions = require("nodemailer-#{transporter}-transport")(transportOptions)

    nodemailer.createTransport(transportOptions).sendMail message, (err, info) =>
      meshblu.message {devices: [fromUuid], result: {error: err?.message,info}}, as: originalDevice, callback

  linkToCredentialsDevice: ({code, owner}, callback) =>
    {uuid, token, verified} = @channelEncryption.codeToAuth code
    return callback(@_userError 'Code could not be verified', 401) unless verified

    userDevice = new UserDevice meshbluConfig: {uuid, token}

    userDevice.getDecryptedOptions (error, options) =>
      return callback error if error?
      clientID = @_getClientID options
      clientSecret = @_getClientSecret options

      @serviceDevice.findOrCreateCredentialsDevice {clientID}, (error, credentialsDevice) =>
        return callback new Error('Could not find or create credentials device') if error?
        credentialsDevice.setClientSecret {clientSecret}, (error) =>
          return callback error if error?
          credentialsDevice.addUserDevice {uuid, token, owner}, (error) =>
            credentialsDevice.getUserDevices callback

  _userError: (message, code) =>
    error = new Error message
    error.code = code
    return error

  _getClientID: (options) =>
    options.auth.user

  _getClientSecret: (options) =>
    options

  _getUserDeviceConfig: (templateOptions)=>
    deviceTemplate = fs.readFileSync './data/device-user-config.json', 'utf8'
    return JSON.parse _.template(deviceTemplate)(templateOptions)

  _getCredentialsDeviceConfig: (templateOptions)=>
    deviceTemplate = fs.readFileSync './data/device-credentials-config.json', 'utf8'
    return JSON.parse _.template(deviceTemplate)(templateOptions)

module.exports = MailerService
