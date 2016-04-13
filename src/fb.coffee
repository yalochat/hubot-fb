try
    {Robot,Adapter,TextMessage,User} = require 'hubot'
catch
    prequire = require('parent-require')
    {Robot,Adapter,TextMessage,User} = prequire 'hubot'

class FBMessenger extends Adapter

    constructor: ->
        super
        @robot.logger.info "Constructor"
        @token      = process.env['FB_PAGE_TOKEN']

    send: (envelope, strings...) ->
        @robot.logger.info "Send"
        message = strings.join "\n"
        @sendAPI envelope.user.id, msg for msg in strings
        
    sendAPI: (user, msg) ->
        self = @
        @robot.http('https://graph.facebook.com/v2.6/me/messages')
            .query({access_token:self.token})
            .header('Content-Type', 'application/json')
            .post(
                JSON.stringify({
                    recipient: {id:user},
                    message: msg
                })) (error, response, body) ->
                    unless response.statusCode in [200, 201]
                        self.robot.logger.error "Send request returned status " +
                        "#{response.statusCode}. user='#{user}' msg='#{msg}'"
                    if error
                        self.robot.logger.error 'Error sending message: ', error
                    else if (response.body.error)
                        self.robot.logger.error 'Error: ', response.body.error
                        
    reply: (envelope, strings...) ->
        @robot.logger.info "Reply"
        @send envelope, strings
        
    run: ->
        self = @
        
        unless @token
            @emit 'error', new Error 'The environment variable "FB_PAGE_TOKEN" is required.'
            
        @robot.http("https://graph.facebook.com/v2.6/me/subscribed_apps")
            .query({access_token:self.token})
            .post() (error, response, body) -> 
                self.robot.logger.info response + " " + body
        
        @robot.router.get ['/hubot/'], (req, res) ->
            if req.param('hub.mode') == 'subscribe' and req.param('hub.verify_token') == 'open_the_pod_bay_doors'
                res.send req.param('hub.challenge')
            else
                res.send 400
                
        @robot.router.post ['/hubot/'], (req, res) ->
            messaging_events = req.body.entry[0].messaging
            self.receive new TextMessage self.robot.brain.userForId(event.sender.id), event.message.text for event in messaging_events
            res.send 200
        
        @robot.logger.info "Run"
        @emit "connected"


exports.use = (robot) ->
    new FBMessenger robot