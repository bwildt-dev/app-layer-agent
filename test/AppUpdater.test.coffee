assert     = require "assert"
{ random } = require "lodash"
spy        = require "spy"

AppUpdater   = require "../src/manager/AppUpdater"
GroupManager = require "../src/manager/GroupManager"
Docker       = require "../src/lib/Docker"

groups            = {}
docker            = new Docker
testContainerName = "app-layer-agent-test-container"

describe ".AppUpdater", ->
	beforeEach ->
		groups =
			default:
				app1:
					containerName: "app1"
					fromImage: "image1:1.0.0"
					labels:
						group: "somegroup"
						manual: false
				app2:
					containerName: "app2"
					fromImage: "image2:3.1.0"
					labels:
						group: "somegroup"
						manual: false
			name:
				app1:
					containerName: "app1"
					fromImage: "image1:2.1.0"
					labels:
						group: "somegroup"
						manual: false
				app2:
					containerName: "app2"
					fromImage: "image2:4.1.0"
					labels:
						group: "somegroup"
						manual: false

	after ->
		docker.removeContainer testContainerName

	afterEach ->
		groups = {}

	it "should error if default group does not exist", ->
		delete groups["default"]

		updater = new AppUpdater

		try
			await updater.queueUpdate groups, []
		catch error
			assert.ok error.message.match /no default group/i

	it "should error if default group is not the first group", ->
		updater      = new AppUpdater
		groups       =
			name:    groups.name
			default: groups["default"]

		try
			await updater.queueUpdate groups, []
		catch error
			assert.ok error.message.match /default group must appear first/i

	it "should be able to convert binds to mounts", ->
		updater = new AppUpdater
		binds   = [
			"/version:/root/.version:ro"
			"/docker:/docker"
			"/data:/data"
		]
		expected = [
			ReadOnly: true
			Source:   "/version"
			Target:   "/root/.version"
			Type:     "bind"
		,
			ReadOnly: false
			Source:   "/docker"
			Target:   "/docker"
			Type:     "bind"
		,
			ReadOnly: false
			Source:   "/data"
			Target:   "/data"
			Type:     "bind"
		]

		assert.deepEqual updater.bindsToMounts(binds), expected

	it.skip "should fail to create if host file does not exist", ->
		docker    = new Docker
		updater   = new AppUpdater docker
		appConfig = updater.normalizeAppConfiguration
			restartPolicy: "always",
			containerName:  testContainerName,
			networkMode:   "host",
			fromImage:     "hello-world",
			detached:      false,
			environment:   [],
			privileged:    true,
			version:       "^1.0.0",
			mounts: [
				"/this/will/never/exist/ok/#{random 0, 1000000}:/version/mount"
			],
			applicationName: testContainerName

		try
			await docker.createContainer appConfig
		catch error
			assert.ok error
			assert.ok error.message.match /bind source path does not exist/i
			assert.equal error.statusCode, 400

	it "should store when handling a collection", (done) ->
		@timeout 3000

		manager                           = new GroupManager
		manager.updateGroupConfigurations = spy manager.updateGroupConfigurations
		updater                           = new AppUpdater {}, {}, manager
		configurations                    = default: {}

		setTimeout ->
			throw new Error "Not updated" unless manager.updateGroupConfigurations.called

			groupConfigurations = manager.getGroupConfigurations()

			assert.ok groupConfigurations isnt configurations
			assert.deepStrictEqual groupConfigurations, configurations
			done()
		, 2500

		updater.handleCollection configurations

	it "should return last known configurations if queueing an update without arguments", (done) ->
		@timeout 3000

		manager                           = new GroupManager
		manager.updateGroupConfigurations = spy manager.updateGroupConfigurations
		manager.updateGroups              = spy manager.updateGroups
		updater                           = new AppUpdater {}, {}, manager
		configurations                    = default: {}

		setTimeout ->
			throw new Error "Not updated (1)" unless manager.updateGroupConfigurations.called
			throw new Error "Not updated (2)" unless manager.updateGroups.called

			updater.doUpdate = (globalGroups, deviceGroups) ->
				assert.deepStrictEqual globalGroups, manager.getGroupConfigurations()
				assert.deepStrictEqual deviceGroups, manager.getGroups()

				done()

				Promise.resolve()

			updater.queueUpdate()
		, 2500

		manager.updateGroups ["default"]
		updater.handleCollection configurations
