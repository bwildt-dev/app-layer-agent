MQTTPattern                             = require "mqtt-pattern"
config                                  = require "config"
fs                                      = require "fs"
mqtt                                    = require "async-mqtt"
{ EventEmitter }                        = require "events"
{ omit, every, isArray, forEach, uniq } = require "lodash"

log = require("./lib/Logger") "Client"

class Client extends EventEmitter
	constructor: ->
		super()

		@options  = config.mqtt
		@clientId = @options.clientId
		@options  = { ...@options, ...@options.extraOptions, will: @getWill() }
		@options  = omit @options, "tls" unless every @options.tls
		@options  = omit @options, "extraOptions"

		@subscribedTopics = []

	constructURL: ->
		protocol = "mqtt"
		protocol = "mqtts" if @options.tls
		host     = @options.host
		port     = @options.port

		"#{protocol}://#{host}:#{port}"

	withTLS: (options) ->
		if options.tls
			options = Object.assign {},
				key:  fs.readFileSync options.tls.key
				ca:   fs.readFileSync options.tls.ca
				cert: fs.readFileSync options.tls.cert
			, options

			options = omit options, "tls"

		options

	connect: ->
		url     = @constructURL()
		options = @withTLS @options

		log.info "Connecting to #{url} ..."

		@mqtt = mqtt.connect url, options
		@mqtt.on "connect", @onConnect

	onConnect: =>
		@mqtt
			.on "packetreceive", @onPacket
			.on "error",         @onError
			.on "reconnect",     @onReconnect
			.on "offline",       @onOffline
			.on "close",         @onClose

		@emit "connect"

	onPacket: (packet) =>
		return unless packet
		return unless packet?.topic
		return unless packet?.cmd is "publish"

		forEach @_events, (fn, topic) =>
			payload  = packet.payload.toString()
			expanded = @expandTopic topic
			return unless MQTTPattern.matches expanded, packet.topic

			@emit topic, packet.topic, payload

	onError: (error) ->
		log.error "Could not connect to the MQTT broker: #{error.message}"

	onReconnect: ->
		log.warn "Reconnecting to the MQTT broker ..."

	onOffline: ->
		log.warn "Disconnected"

	onClose: =>
		@mqtt
			.removeListener "packetreceive", @onPacket
			.removeListener "error",         @onError
			.removeListener "reconnect",     @onReconnect
			.removeListener "offline",       @onOffline
			.removeListener "close",         @onClose

		@emit "close"

	getWill: ->
		topic:   "devices/#{@clientId}/status"
		payload: "offline"
		retain:  true

	expandTopic: (topic) =>
		topic.replace /{id}/g, @clientId

	createTopic: (topic) ->
		rootTopic = "devices/#{@clientId}"
		topic     = topic.replace rootTopic, ""

		rootTopic
			.concat topic
			.replace /\/{2,}/, ""

	fork: ->
		throw new Error "You must connect to the broker before you can fork the MQTT client" unless @mqtt
		@mqtt

	publish: (topic, message, options = {}) ->
		@mqtt.publish @createTopic(topic), message, options

	subscribe: (topics) ->
		@connect() unless @mqtt

		topics            = [topics] unless isArray topics
		topics            = topics.map @expandTopic
		@subscribedTopics = uniq @subscribedTopics.concat topics

		@mqtt.subscribe topics

module.exports = Client
