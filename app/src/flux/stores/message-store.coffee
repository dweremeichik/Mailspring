NylasStore = require "nylas-store"
Actions = require("../actions").default
Message = require("../models/message").default
Thread = require("../models/thread").default
Utils = require '../models/utils'
DatabaseStore = require("./database-store").default
TaskFactory = require("../tasks/task-factory").default
FocusedPerspectiveStore = require('./focused-perspective-store').default
FocusedContentStore = require("./focused-content-store").default
NylasAPIHelpers = require '../nylas-api-helpers'
ExtensionRegistry = require('../../registries/extension-registry')
async = require 'async'
_ = require 'underscore'

FolderNamesHiddenByDefault = ['spam', 'trash']

class MessageStore extends NylasStore

  constructor: ->
    @_setStoreDefaults()
    @_registerListeners()

  ########### PUBLIC #####################################################

  items: ->
    return @_items if @_showingHiddenItems

    viewing = FocusedPerspectiveStore.current().categoriesSharedRole()
    viewingHiddenCategory = viewing in FolderNamesHiddenByDefault

    if viewingHiddenCategory
      return @_items.filter (item) ->
        inHidden = item.folder.role in FolderNamesHiddenByDefault
        return inHidden or item.draft is true
    else
      return @_items.filter (item) ->
        inHidden = item.folder.role in FolderNamesHiddenByDefault
        return not inHidden

  threadId: -> @_thread?.id

  thread: -> @_thread

  itemsExpandedState: =>
    # ensure that we're always serving up immutable objects.
    # this.state == nextState is always true if we modify objects in place.
    _.clone @_itemsExpanded

  hasCollapsedItems: ->
    _.size(@_itemsExpanded) < @_items.length

  numberOfHiddenItems: ->
    @_items.length - @items().length

  itemIds: ->
    _.pluck(@_items, "id")

  itemsLoading: ->
    @_itemsLoading

  ###
  Message Store Extensions
  ###

  # Public: Returns the extensions registered with the MessageStore.
  extensions: =>
    ExtensionRegistry.MessageView.extensions()

  _onExtensionsChanged: (role) ->
    MessageBodyProcessor = require('./message-body-processor').default
    MessageBodyProcessor.resetCache()


  ########### PRIVATE ####################################################

  _setStoreDefaults: =>
    @_items = []
    @_itemsExpanded = {}
    @_itemsLoading = false
    @_showingHiddenItems = false
    @_thread = null

  _registerListeners: ->
    @listenTo ExtensionRegistry.MessageView, @_onExtensionsChanged
    @listenTo DatabaseStore, @_onDataChanged
    @listenTo FocusedContentStore, @_onFocusChanged
    @listenTo FocusedPerspectiveStore, @_onPerspectiveChanged
    @listenTo Actions.toggleMessageIdExpanded, @_onToggleMessageIdExpanded
    @listenTo Actions.toggleAllMessagesExpanded, @_onToggleAllMessagesExpanded
    @listenTo Actions.toggleHiddenMessages, @_onToggleHiddenMessages
    @listenTo Actions.popoutThread, @_onPopoutThread
    @listenTo Actions.focusThreadMainWindow, @_onFocusThreadMainWindow

  _onPerspectiveChanged: =>
    @trigger()

  _onDataChanged: (change) =>
    return unless @_thread

    if change.objectClass is Message.name
      inDisplayedThread = _.some change.objects, (obj) => obj.threadId is @_thread.id
      return unless inDisplayedThread

      if change.objects.length is 1 and change.objects[0].draft is true
        item = change.objects[0]
        itemIndex = _.findIndex @_items, (msg) -> msg.id is item.id

        if change.type is 'persist' and itemIndex is -1
          @_items = [].concat(@_items, [item]).filter((m) => !m.isHidden())
          @_items = @_sortItemsForDisplay(@_items)
          @_expandItemsToDefault()
          @trigger()
          return

        if change.type is 'unpersist' and itemIndex isnt -1
          @_items = [].concat(@_items).filter((m) => !m.isHidden())
          @_items.splice(itemIndex, 1)
          @_expandItemsToDefault()
          @trigger()
          return

      @_fetchFromCache()

    if change.objectClass is Thread.name
      updatedThread = change.objects.find((t) => t.id is @_thread.id)
      if updatedThread
        @_thread = updatedThread
        @_fetchFromCache()

  _onFocusChanged: (change) =>
    return unless change.impactsCollection('thread')

    # This implements a debounce that fires on the leading and trailing edge.
    #
    # If we haven't changed focus in the last 100ms, do it immediately. This means
    # there is no delay when moving to the next thread, deselecting a thread, etc.
    #
    # If we have changed focus in the last 100ms, wait for focus changes to
    # stop arriving for 100msec before applying. This means that flying
    # through threads doesn't cause is to make a zillion queries for messages.
    #
    if not @_onFocusChangedTimer
      @_onApplyFocusChange()
    else
      clearTimeout(@_onFocusChangedTimer)

    @_onFocusChangedTimer = setTimeout =>
      @_onFocusChangedTimer = null
      @_onApplyFocusChange()
    , 100

  _onApplyFocusChange: =>
    focused = FocusedContentStore.focused('thread')
    return if @_thread?.id is focused?.id

    @_thread = focused
    @_items = []
    @_itemsLoading = true
    @_showingHiddenItems = false
    @_itemsExpanded = {}
    @trigger()

    @_fetchFromCache()

  _markAsRead: ->
    # Mark the thread as read if necessary. Make sure it's still the
    # current thread after the timeout.
    #
    # Override canBeUndone to return false so that we don't see undo
    # prompts (since this is a passive action vs. a user-triggered
    # action.)
    return if not @_thread
    return if @_lastLoadedThreadId is @_thread.id
    @_lastLoadedThreadId = @_thread.id

    if @_thread.unread
      markAsReadDelay = NylasEnv.config.get('core.reading.markAsReadDelay')
      markAsReadId = @_thread.id
      return if markAsReadDelay < 0

      setTimeout =>
        return unless markAsReadId is @_thread?.id and @_thread.unread
        Actions.queueTask(TaskFactory.taskForInvertingUnread({
          threads: [@_thread],
          source: "Thread Selected",
          canBeUndone: false,
          unread: false,
        }))
      , markAsReadDelay

  _onToggleAllMessagesExpanded: =>
    if @hasCollapsedItems()
      @_items.forEach @_expandItem
    else
      # Do not collapse the latest message, i.e. the last one
      @_items[...-1].forEach @_collapseItem
    @trigger()

  _onToggleHiddenMessages: =>
    @_showingHiddenItems = !@_showingHiddenItems
    @_expandItemsToDefault()
    @_fetchExpandedAttachments(@_items)
    @trigger()

  _onToggleMessageIdExpanded: (id) =>
    item = _.findWhere(@_items, {id})
    return unless item

    if @_itemsExpanded[id]
      @_collapseItem(item)
    else
      @_expandItem(item)
    @trigger()

  _expandItem: (item) =>
    @_itemsExpanded[item.id] = "explicit"
    @_fetchExpandedAttachments([item])

  _collapseItem: (item) =>
    delete @_itemsExpanded[item.id]

  _fetchFromCache: (options = {}) ->
    return unless @_thread

    loadedThreadId = @_thread.id

    query = DatabaseStore.findAll(Message)
    query.where(threadId: loadedThreadId)
    query.include(Message.attributes.body)
    query.then (items) =>
      # Check to make sure that our thread is still the thread we were
      # loading items for. Necessary because this takes a while.
      return unless loadedThreadId is @_thread?.id

      @_items = items.filter((m) => !m.isHidden())
      @_items = @_sortItemsForDisplay(@_items)

      @_expandItemsToDefault()

      if @_itemsLoading
        @_fetchMissingBodies(@_items)

      # Download the attachments on expanded messages.
      @_fetchExpandedAttachments(@_items)

      # Normally, we would trigger often and let the view's
      # shouldComponentUpdate decide whether to re-render, but if we
      # know we're not ready, don't even bother.  Trigger once at start
      # and once when ready. Many third-party stores will observe
      # MessageStore and they'll be stupid and re-render constantly.
      @_itemsLoading = false
      @_markAsRead()
      @trigger(@)

  _fetchMissingBodies: (items) ->
    missing = items.filter((i) -> i.body == null);
    if missing.length > 0
      Actions.fetchBodies(missing)

  _fetchExpandedAttachments: (items) ->
    policy = NylasEnv.config.get('core.attachments.downloadPolicy')
    return if policy is 'manually'

    for item in items
      continue unless @_itemsExpanded[item.id]
      for file in item.files
        Actions.fetchFile(file)

  # Expand all unread messages, all drafts, and the last message
  _expandItemsToDefault: ->
    visibleItems = @items()
    lastDraftIdx = -1
    visibleItems.forEach (item, idx) ->
      lastDraftIdx = idx if item.draft
    
    for item, idx in visibleItems
      if item.unread or idx is lastDraftIdx or idx is visibleItems.length - 1
        @_itemsExpanded[item.id] = "default"

  _sortItemsForDisplay: (items) ->
    # Re-sort items in the list so that drafts appear after the message that
    # they are in reply to, when possible. First, identify all the drafts
    # with a replyToHeaderMessageId and remove them
    itemsInReplyTo = []
    for item, index in items by -1
      if item.draft and item.replyToHeaderMessageId
        itemsInReplyTo.push(item)
        items.splice(index, 1)

    # For each item with the reply header, re-inset it into the list after
    # the message which it was in reply to. If we can't find it, put it at the end.
    for item in itemsInReplyTo
      for other, index in items
        if item.replyToHeaderMessageId is other.headerMessageId
          items.splice(index+1, 0, item)
          item = null
          break
      if item
        items.push(item)

    items

  _onPopoutThread: (thread) ->
    NylasEnv.newWindow
      title: false, # MessageList already displays the thread subject
      hidden: false,
      windowKey: "thread-#{thread.id}",
      windowType: 'thread-popout',
      windowProps:
        threadId: thread.id,
        perspectiveJSON: FocusedPerspectiveStore.current().toJSON()

  _onFocusThreadMainWindow: (thread) ->
    if NylasEnv.isMainWindow()
      Actions.setFocus({collection: 'thread', item: thread})
      NylasEnv.focus()


store = new MessageStore()
store.FolderNamesHiddenByDefault = FolderNamesHiddenByDefault

module.exports = store
