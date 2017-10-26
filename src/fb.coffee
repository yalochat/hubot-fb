try
  {Robot,Adapter,TextMessage,User} = require 'hubot'
catch
  prequire = require('parent-require')
  {Robot,Adapter,TextMessage,User} = prequire 'hubot'

Mime = require 'mime'
Promise = require 'bluebird'
crypto = require 'crypto'
inspect = require('util').inspect
metricsToken = process.env.METRICS_TOKEN or null
botmetrics = require('node-botmetrics')(metricsToken).facebook
Analytics = require '@engyalo/fb-messenger-events'


class FBMessenger extends Adapter

  constructor: ->
    super
    @page_id    = process.env['FB_PAGE_ID']
    @app_id     = process.env['FB_APP_ID']
    @app_secret = process.env['FB_APP_SECRET']

    @token      = process.env['FB_PAGE_TOKEN']
    @vtoken     = process.env['FB_VERIFY_TOKEN'] or\
    crypto.randomBytes(16).toString('hex')

    @routeURL   = process.env['FB_ROUTE_URL'] or '/hubot/fb'
    @webhookURL = process.env['FB_WEBHOOK_BASE'] + @routeURL
    @setWebHook = @toBool(process.env['FB_SET_WEBHOOK'] or false)

    @commentsToken = process.env['FB_COMMENTS_TOKEN'] or null

    @slackWebhook = process.env['SLACK_WEBHOOK'] or null
    @httpErrors = 0
    @httpErrorsMax = process.env['HTTP_ERRORS_MAX'] or 3

    @typingIndicatorsMultiplier = process.env['TYPING_INDICATORS_MULTIPLIER']\
    or 1

    @hooksUrl = process.env['HOOKS_HOST'] or null
    @botId = process.env['BOT_RUNNING'] or null

    @pagesUrl = process.env['PAGES_URL'] or null

    _sendImages = process.env['FB_SEND_IMAGES']
    if _sendImages is undefined
      @sendImages = true
    else
      @sendImages = _sendImages is 'true'

    @autoHear = process.env['FB_AUTOHEAR'] is 'true'

    @apiURL = 'https://graph.facebook.com/v2.6'
    @pageURL = @apiURL + '/' + @page_id
    @messageEndpoint = @pageURL + '/messages?access_token=' + @token
    @subscriptionEndpoint = @pageURL + '/subscribed_apps?access_token=' + @token
    @appAccessTokenEndpoint = "https://graph.facebook.com/oauth/access_token?" +
    "client_id=#{@app_id}&client_secret=#{@app_secret}&" +
    "grant_type=client_credentials"
    @setWebhookEndpoint = @pageURL + '/subscriptions'

    @defaultUserName = process.env['USER_DEFAULT_NAME'] or ""
    @defaultUserLastName = process.env['USER_DEFAULT_LAST_NAME'] or ""
    @defaultUserPicture = process.env['USER_DEFAULT_PICTURE'] or ""

    @msg_maxlength = 640
    @special_command = process.env['SPECIAL_COMMAND'] or "/"

    Analytics.init @botId, @app_id, @page_id

  send: (envelope, templates...) ->
    self = @
    Promise.each(templates, ({slug, template}) ->
      if template.type is 'text'
        delete template.type
      self._sendRich(envelope.user.id, envelope.room, template, slug)
    )


  _sendText: (user, pageId, msg, slug) ->
    data = {
      recipient: {id: user},
      message: {}
    }

    if @sendImages
      mime = Mime.lookup(msg)

      if mime is 'image/jpeg' or mime is 'image/png' or mime is 'image/gif'
        data.message.attachment = { type: 'image', payload: { url: msg }}
      else
        data.message.text = msg.substring(0, @msg_maxlength)
    else
      data.message.text = msg

    @_sendMessage data, pageId, slug

  _sendRich: (user, pageId, richMsg, slug) ->
    data = {
      recipient: {id: user},
      message: richMsg
    }
    @_sendMessage data, pageId, slug

  _calculateReadingTime: (text) ->
    (text.split(' ').length / 5) * 1100

  _sendMessage: (data, pageId, slug) ->
    self = @


    # Calculate timeout for send message
    timeout = 0
    if data.message.text?
      timeout = self._calculateReadingTime(data.message.text)\
      * @typingIndicatorsMultiplier
    else
      timeout = 3000  * @typingIndicatorsMultiplier

    # Send message applying timeout in seconds
    return self._sendAPI(data, pageId, timeout, slug)


  _sendToSlack: (text) ->
    self = @
    if (self.slackWebhook)
      if (self.httpErrors >= self.httpErrorsMax)
        obj = {text:"#{text} \n *bot: #{self.robot.name}* \n @eng"}
        data = JSON.stringify(obj)
        self.robot.http(@slackWebhook)
          .header('Content-Type', 'application/json')
          .post(data) (err, response, body) ->
            if (err)
              self.robot.logger.error "Error trying to\
              send notification to slack - #{err}"
            self.httpErrors = 0
      else
        self.httpErrors++

    else
      @robot.logger.error "Trying to send notification to " +
      "slack but I don't have a slack webhook"

  _sendAPI: (data, pageId, timeout = 0, slug) ->
    self = @
    fbData = JSON.stringify data

    request = new Promise((resolve, reject) ->
      self._getAndSetPage pageId, (page) ->
        unless self.hooksUrl
          url = self.messageEndpoint
          query = access_token: self.token
        else if page?
          url = "#{self.hooksUrl}/bots/#{page.id}"
          query = {}
        else
          return reject(new Error "Page with id: #{pageId} doesn't exists'")

        self.robot
          .http(url)
          .header('Content-Type', 'application/json')
          .query(query)
          .post(fbData) (error, response, body) ->
            if error
              self.robot.logger.error "Error sending message: #{error}"
              self._sendToSlack "Error sending message to facebook webhook" +
              "\n#{error}"
              return reject(error)

            if response.statusCode in [200, 201]
              self.robot.logger.info "Send request returned status \
              #{response.statusCode}, data #{JSON.stringify(data)}"
              self.robot.logger.info response.body
            else
              try
                errMsg = JSON.parse body
                self.robot.logger.error "Facebook webhook responded with \
                an error #{errMsg.error.message}"
                self._sendToSlack "Facebook webhook responded with an \
                error\n #{errMsg.error.message}"
              catch e
                self.robot.emit 'errorSendAPI',slug,data.recipient.id
                self.robot.logger.error "Error parsing JSON #{body}"
                return reject(new Error('Cannot send message to Facebook'))

              # If error doesn't exists, then track message
              botmetrics.trackOutgoing(data)
              resolve({ statusCode: response.statusCode, body })
    )

    Promise.delay(timeout, request)

  _receiveAPI: (event) ->
    self = @

    # Validate if message is from bot
    if event.message?.app_id? == self.app_id
      self.robot.logger.debug "Skipping incoming request, is an echo from bot"
      +" message."
      return
    # Make payload used to send typing event
    typing =
      recipient:
        id: event.sender.id
      sender_action: 'typing_on'

    # Send event typing if theres a message on the event.
    if event.message || event.postback
      @_sendAPI(typing)

    @robot.brain.userById event.sender.id
    .then (user) ->
      unless user?
        self.robot.logger.debug "User doesn't exist, creating"
        if event.message?.is_echo
          event.sender.id = event.recipient.id
        self._getUser event.sender.id, event.recipient.id,\
        event.message?.is_echo, (user) ->
          self._dispatch event, user
      else
        self.robot.logger.debug "User exists"
        self._dispatch event, user


  _receiveComment: (event) ->
    self = @
    if event.value?.item == 'comment'
      @robot.emit "fb_comment", event

  reply: (envelope, commentId, reply) ->
    self = @
    url = self.apiURL + "/#{commentId}/private_replies?access_token=#{self.commentsToken}"
    @robot.http(url)
    .query({message: reply})
    .post() (error, response, body) ->
      if response.statusCode != 200
        self.robot.logger.error "Response code -> #{response.statusCode} \
        Response message -> #{body}"
        return
      self.robot.logger.info "reply to comment: \
      #{body} #{response.statusCode}"

  _dispatch: (event, user) ->
    envelope = {
      event: event,
      user: user,
      room: event.recipient.id
    }

    if event.message?
      @_processMessage event, envelope
    else if event.postback?
      @_processPostback event, envelope
    else if event.referral?
      @_processReferral event, envelope
    else if event.delivery?
      @_processDelivery event, envelope
    else if event.optin?
      @_processOptin event, envelope

  _processMessage: (event, envelope) ->
    @robot.logger.debug inspect event.message
    if event.message.attachments?
      envelope.attachments = event.message.attachments
      @robot.emit "fb_richMsg", envelope
      @_processAttachment event, envelope, attachment\
      for attachment in envelope.attachments
    if event.message.text?
      text = if @autoHear then @_autoHear event.message.text,\
      envelope.room else event.message.text
      msg = new TextMessage envelope.user, text, event.message.mid
      if event.message.quick_reply?.payload?
        @_processPostbackQuickReply event, envelope
        #@receive msg
      else
        if envelope.user.admin
          if text.startsWith('/') or text.startsWith(@special_command) 
            @receive msg
          else
            msg = new TextMessage envelope.user, '/botOff', event.message.mid
            @receive msg
        else
          @receive msg
      @robot.logger.info "Reply message to room/message: \
      #{envelope.user.name}/#{event.message.mid}"

  _autoHear: (text, chat_id) ->
    # If it is a private chat, automatically prepend the bot name
    # if it does not exist already.
    if (chat_id > 0)
      # Strip out the stuff we don't need.
      text = text.replace(new RegExp('^@?' + @robot.name.toLowerCase(), \
       'gi'), '')
      text = text.replace(new RegExp('^@?' + @robot.alias.toLowerCase(), \
      'gi'), '') if @robot.alias
      text = @robot.name + ' ' + text

    return text

  _processAttachment: (event, envelope, attachment) ->
    unique_envelope = {
      event: event,
      user: envelope.user,
      room: envelope.room,
      attachment: attachment
    }
    @robot.emit "fb_richMsg_#{attachment.type}", unique_envelope

  _processPostbackQuickReply: (event,envelope) ->
    envelope.payload =  if event.message.quick_reply.payload != 'null'\
    then event.message.quick_reply.payload else event.message.text
    Analytics.track(envelope.user.id,envelope.payload)
    @robot.emit "fb_postback", envelope

  _processPostback: (event, envelope) ->
    envelope.payload = event.postback.payload
    envelope.referral = event.postback.referral?.ref
    Analytics.track(envelope.user.id,envelope.payload)
    if envelope.referral
      @robot.emit "fb_referral", envelope
    else
      @robot.emit "fb_postback", envelope

  _processReferral: (event, envelope) ->
    envelope.referral = event.referral.ref
    @robot.emit "fb_referral", envelope

  _processDelivery: (event, envelope) ->
    @robot.emit "fb_delivery", envelope

  _processOptin: (event, envelope) ->
    envelope.ref = event.optin.ref
    @robot.emit "fb_optin", envelope
    @robot.emit "fb_authentication", envelope

  _getAndSetPage: (pageId, callback) ->
    self = @
    # Get page information based on room id if @pagesUrl has been assigned
    if @pagesUrl
      pagePromise = @robot.brain.get pageId
      pagePromise.then (page) ->
        unless page?
          @_getPageFromAPI pageId, (newPage) ->
            if page?
              setPromise = self.robot.brain.set pageId, newPage
              setPromise.then (data) ->
                callback newPage
              setPromise.catch (error) ->
                self.robot.logger.error "Error setting pageId", error
                callback null
            else
              callback page
        else
          callback page
      pagePromise.catch (error) ->
        self.robot.logger.error "Error getting pageId", error
        callback null
    else
      callback null

  _getPageFromAPI: (pageId, callback) ->
    self = @

    url = "#{@pagesUrl}/pages"
    query =
        q: "page_id:#{pageId}"

    @robot.http(url)
    .query(query)
    .get() (error, response, body) ->
      if error
        self.robot.logger.error "Error getting page: #{error}"
        callback null
        return

      unless response.statusCode is 200
        errMsg = "Get page with id: #{pageId} \
        returned status #{response.statusCode}"
        self.robot.logger.error errMsg
        callback null
        return

      { data:page } = JSON.parse body

      callback page


  _getUser: (userId, pageId ,isAdmin, callback) ->
    self = @

    self._getAndSetPage pageId, (page) ->
      unless self.hooksUrl
        url = "#{self.apiURL}/#{userId}"
        query =
            fields: "first_name,last_name"
            access_token:self.token
      else if page?
        url = "#{self.hooksUrl}/bots/#{page.id}/users/#{userId}"
        query = {}
      else
        return reject(new Error "Page with id: #{pageId} doesn't exists'")

      self.robot.http(url)
      .query(query)
      .get() (error, response, body) ->
        if error
          errMsg = "Error getting user profile: #{error}"
          self.robot.logger.error errMsg
          self._sendToSlack errMsg
          return
        unless response.statusCode is 200
          errMsg = "Get user profile request returned status " +
          "#{response.statusCode}. data='#{body}'"
          self.robot.logger.error errMsg
          self._sendToSlack errMsg
          self.robot.logger.error body
          body = "{\"first_name\":\"#{self.defaultUserName}\",\
          \"last_name\":\"#{self.defaultUserLastName}\"\,\
          \"profile_pic\":\"#{self.defaultUserPicture}\"}"
        userData = JSON.parse body

        userData.name = userData.first_name
        userData.room = pageId
        userData.admin = isAdmin
        userData.id = userId

        user = new User userId, userData
        if !isAdmin
          saveUserPromise = self.robot.brain.userForId userId, userData
          saveUserPromise.then (result) ->
            callback user
        else
          callback user

  toBool: (string) ->
    areTrue = [
        'yes',
        'true',
        true,
        'y',
        1,
        '1'
    ]

    if(typeof string is 'string')
      string = string.toLowerCase()

    if(areTrue.indexOf(string)  > -1)
      return true

    return false


  run: ->
    self = @

    if @setWebHook
      unless @token
        @emit 'error', new Error 'The environment variable "FB_PAGE_TOKEN" \
        is required when you set the variable "FB_SET_WEBHOOK equals true".\
         See https://github.com/chen-ye/hubot-fb/blob/master/README.md for \
         details.'

      unless @webhookURL
        @emit 'error', new Error 'The environment variable "FB_WEBHOOK_BASE"\
         is required when you set the variable "FB_SET_WEBHOOK equals true. \
         See https://github.com/chen-ye/hubot-fb/blob/master/README.md for \
         details.'
    else
      unless @hooksUrl
        @emit 'error', new Error 'The environment variable "HOOKS_HOST" \
        is required'

      unless @pagesUrl
        @emit 'error', new Error 'The environment variable "PAGES_URL" \
        is required'


    unless @page_id
      @emit 'error', new Error 'The environment variable "FB_PAGE_ID" is \
      required. See https://github.com/chen-ye/hubot-fb/blob/master/README.md \
      for details.'

    unless @app_id
      @emit 'error', new Error 'The environment variable "FB_APP_ID" is \
      required. See https://github.com/chen-ye/hubot-fb/blob/master/README.md \
      for details.'

    unless @app_secret
      @emit 'error', new Error 'The environment variable "FB_APP_SECRET" is \
      required. See https://github.com/chen-ye/hubot-fb/blob/master/README.md\
       for details.'

    unless @botId
      @emit 'error', new Error 'The environment variable "BOT_ID" is required'

    @robot.router.get [@routeURL], (req, res) ->
      if req.param('hub.mode') == 'subscribe' and \
      req.param('hub.verify_token') == self.vtoken
        res.send req.param('hub.challenge')
        self.robot.logger.info "successful webhook verification"
      else
        res.send 400

    @robot.router.post [@routeURL], (req, res) ->
      self.robot.logger.debug "Received payload: %j", req.body
      botmetrics.trackIncoming(req.body)
      [entry] = req.body.entry
      if entry.changes?.length > 0
        self._receiveComment entry.changes[0]
      else
        messaging_events = entry.messaging
        self._receiveAPI event for event in messaging_events
      res.send 200

    # Suscribe to app and update FB webhook
    if @setWebHook
      @robot.http(@subscriptionEndpoint)
      .query({access_token:self.token})
      .post() (error, response, body) ->
        if response.statusCode != 200
          self.robot.logger.error "Response code -> #{response.statusCode} \
          Response message -> #{body}"
          process.exit 0
        self.robot.logger.info "subscribed app to page: \
        #{body} #{response.statusCode}"

      @robot.http(@appAccessTokenEndpoint)
      .get() (error, response, body) ->
        response = JSON.parse(body)
        self.app_access_token = response.access_token
        self.robot.http(self.setWebhookEndpoint)
        .query(
          object: 'page',
          callback_url: self.webhookURL
          fields: 'messaging_optins, messages, message_deliveries,\
          messaging_postbacks'
          verify_token: self.vtoken
          access_token: self.app_access_token
        )
        .post() (error2, response2, body2) ->
          self.robot.logger.info "FB webhook set/updated: " + body2

      @robot.logger.info "FB-adapter initialized"
      @emit "connected"


exports.use = (robot) ->
  new FBMessenger robot
