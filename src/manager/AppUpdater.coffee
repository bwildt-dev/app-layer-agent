config                                          = require "config"
debug                                           = (require "debug") "app:AppUpdater"
queue                                           = require "async.queue"
{ createGroupsMixin, getAppsToChange }          = require "@viriciti/app-layer-logic"
{ isEmpty, pickBy, first, debounce, map, omit } = require "lodash"
{ yellow }                                      = require "kleur"

log = (require "../lib/Logger") "AppUpdater"

class AppUpdater
	constructor: (@docker, @state, @groupManager) ->
		@handleCollection = debounce @handleCollection, 2000
		@queue            = queue @handleUpdate

	handleUpdate: ({ fn }, cb) ->
		fn cb

	handleCollection: (groups) =>
		return log.error "No applications available (empty groups)" if isEmpty groups

		@groupManager.updateGroupConfigurations groups

		names  = @groupManager.getGroups()
		groups = pickBy @groupManager.getGroupConfigurations(), (_, name) -> name in names

		@queueUpdate groups, names

	queueUpdate: (globalGroups, groups) ->
		globalGroups or= @groupManager.getGroupConfigurations()
		groups       or= @groupManager.getGroups()

		log.info "Update queued"

		@queue.push
			fn: (cb) =>
				@doUpdate globalGroups, groups
					.then ->
						cb()
					.catch (error) ->
						log.error "Failed to update: #{error.message}"
						cb error

	doUpdate: (globalGroups, groups) ->
		debug "Updating..."
		debug "Global groups are", globalGroups
		debug "Device groups are", groups

		return new Error "No global groups"                if isEmpty globalGroups
		return new Error "No default group"                unless globalGroups["default"]
		return new Error "Default group must appear first" unless first(Object.keys globalGroups) is "default"

		currentApps     = await @docker.listContainers()
		currentApps     = {} unless config.docker.container.allowRemoval
		currentApps     = omit currentApps, config.docker.container.whitelist
		extendedGroups = createGroupsMixin globalGroups,   groups
		appsToChange   = getAppsToChange   extendedGroups, currentApps

		@state.sendNsState
			updateState:
				short: "Idle"
				long:  "Idle"

		return unless appsToChange.install.length or appsToChange.remove.length

		message = []

		if appsToChange.install.length
			message.push "Installing: #{map(appsToChange.install, "applicationName").join ", "}"
			log.info "Installing #{appsToChange.install.length} application(s)"
		else
			log.warn "No applications to install"

		if appsToChange.remove.length
			message.push "Removing: #{appsToChange.remove.join ", "}"
			log.info "Removing #{appsToChange.remove.length} application(s)"
		else
			log.warn "No applications to remove"

		@state.sendNsState
			updateState:
				short: "Updating applications ..."
				long:  message.join "\n"

		try
			await @docker.removeUntaggedImages()
			await @removeApps  appsToChange.remove
			await @installApps appsToChange.install
			await @docker.removeOldImages()

			@state.sendNsState
				updateState:
					short: "Idle"
					long:  "Idle"
		catch error
			log.error yellow "Failed to update: #{error.message}"

			@state.sendNsState
				updateState:
					short: "ERROR"
					long:  error.message
		finally
			@state.throttledSendState()

	removeApps: (apps) ->
		await Promise.all apps.map (app) =>
			@docker.removeContainer
				id:    app
				force: true

	installApps: (apps) ->
		await Promise.all apps.map (app) =>
			@installApp app

	installApp: (appConfig) ->
		normalized = @normalizeAppConfiguration appConfig

		return if @isPastLastInstallStep "Pull", appConfig.lastInstallStep
		await @docker.pullImage name: normalized.Image

		return if @isPastLastInstallStep "Clean", appConfig.lastInstallStep
		
		await @docker.removeContainer id: normalized.name, force: true

		return if @isPastLastInstallStep "Create", appConfig.lastInstallStep
		await @docker.createContainer normalized

		return if @isPastLastInstallStep "Start", appConfig.lastInstallStep
		await @docker.startContainer normalized.name

		log.info "Application #{normalized.name} installed correctly"

	isPastLastInstallStep: (currentStepName, endStepName) ->
		return false unless endStepName?

		steps = ["Pull", "Clean", "Create", "Start"]

		currentStep = steps.indexOf(currentStepName) + 1
		endStep     = steps.indexOf(endStepName)     + 1

		currentStep > endStep

	normalizeAppConfiguration: (appConfiguration) ->
		name:         appConfiguration.containerName
		AttachStdin:  not appConfiguration.detached
		AttachStdout: not appConfiguration.detached
		AttachStderr: not appConfiguration.detached
		Env:          appConfiguration.environment
		Cmd:          appConfiguration.entryCommand
		Image:        appConfiguration.fromImage
		Labels:       appConfiguration.labels #NOTE https://docs.docker.com/config/labels-custom-metadata/#value-guidelines
		HostConfig:
			Binds:         appConfiguration.mounts
			NetworkMode:   appConfiguration.networkMode
			Privileged:    not not appConfiguration.privileged
			RestartPolicy: Name: appConfiguration.restartPolicy
			PortBindings:  appConfiguration.ports

	# unused for now
	bindsToMounts: (binds) ->
		binds.map (bind) ->
			[source, target, ro] = bind.split ":"

			ReadOnly: not not ro
			Source:   source
			Target:   target
			Type:     "bind"

module.exports = AppUpdater
