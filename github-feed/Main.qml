import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.UI

Item {
    id: root

    property var pluginApi: null

    property var rawEvents: []
    readonly property var events: filterEvents(rawEvents)

    property var followingList: []
    property bool isLoading: false
    property bool hasError: false
    property string errorMessage: ""
    property int lastFetchTimestamp: 0

    readonly property string username: pluginApi?.pluginSettings?.username || ""
    readonly property string token: pluginApi?.pluginSettings?.token || ""
    readonly property int refreshInterval: pluginApi?.pluginSettings?.refreshInterval || 1800
    readonly property int maxEvents: pluginApi?.pluginSettings?.maxEvents || 50

    readonly property bool showStars: pluginApi?.pluginSettings?.showStars ?? true
    readonly property bool showForks: pluginApi?.pluginSettings?.showForks ?? true
    readonly property bool showPRs: pluginApi?.pluginSettings?.showPRs ?? true
    readonly property bool showIssues: pluginApi?.pluginSettings?.showIssues ?? true
    readonly property bool showPushes: pluginApi?.pluginSettings?.showPushes ?? false

    readonly property string cacheDir: pluginApi?.pluginDir ? pluginApi.pluginDir + "/cache" : ""
    readonly property string eventsCachePath: cacheDir + "/events.json"
    readonly property string avatarsDir: cacheDir + "/avatars"

    property var receivedEvents: []
    property var myRepoEvents: []
    property var userRepos: []
    property int pendingFetches: 0
    property var availableAvatars: ({})

    function filterEvents(rawList) {
        if (!rawList || rawList.length === 0) return []

        var filtered = rawList.filter(function(event) {
            switch (event.type) {
                case "WatchEvent":
                    return root.showStars
                case "ForkEvent":
                    return root.showForks
                case "PullRequestEvent":
                    return root.showPRs
                case "IssuesEvent":
                    return root.showIssues
                case "PushEvent":
                    return root.showPushes
                default:
                    return true
            }
        })

        return filtered.slice(0, root.maxEvents)
    }

    FileView {
        id: eventsCacheFile
        path: root.eventsCachePath
        watchChanges: false

        onLoaded: {
            Logger.d("GitHubFeed", "Cache loaded from disk")
            loadFromCache()
        }

        onLoadFailed: function(error) {
            Logger.d("GitHubFeed", "No cache file found, will fetch fresh data")
            if (root.username) {
                fetchFromGitHub()
            }
        }

        JsonAdapter {
            id: cacheAdapter
            property var events: []
            property int timestamp: 0
        }
    }

    function loadFromCache() {
        try {
            var content = eventsCacheFile.text()
            if (!content || content.trim() === "") {
                if (root.username) fetchFromGitHub()
                return
            }

            var cached = JSON.parse(content)
            if (!cached || !cached.events) {
                if (root.username) fetchFromGitHub()
                return
            }

            root.lastFetchTimestamp = cached.timestamp || 0
            root.followingList = cached.following || []
            var now = Math.floor(Date.now() / 1000)
            var age = now - root.lastFetchTimestamp

            if (age < root.refreshInterval) {
                root.rawEvents = cached.events
                Logger.i("GitHubFeed", "Using cached data, age: " + Math.floor(age / 60) + " min")
            } else {
                Logger.i("GitHubFeed", "Cache expired, fetching fresh data")
                if (root.username) fetchFromGitHub()
            }
        } catch (e) {
            Logger.e("GitHubFeed", "Failed to parse cache:", e)
            if (root.username) fetchFromGitHub()
        }
    }

    function saveToCache() {
        if (!root.cacheDir) return

        cacheAdapter.events = root.rawEvents
        cacheAdapter.timestamp = Math.floor(Date.now() / 1000)
        eventsCacheFile.writeAdapter()

        Logger.d("GitHubFeed", "Cache saved with " + root.rawEvents.length + " raw events")
    }

    function buildCurlCommand(url) {
        var cmd = ["curl", "-s", "-L", "--compressed", "--connect-timeout", "10", "--max-time", "30"]

        if (root.token && root.token.trim() !== "") {
            cmd.push("-H")
            cmd.push("Authorization: Bearer " + root.token)
        }

        cmd.push("-H")
        cmd.push("Accept: application/vnd.github.v3+json")
        cmd.push("-H")
        cmd.push("User-Agent: noctalia-github-feed")
        cmd.push(url)

        return cmd
    }

    function handleApiError(data, context) {
        if (data && data.message) {
            var msg = data.message
            Logger.e("GitHubFeed", context + " API error:", msg)

            if (msg.indexOf("rate limit") !== -1) {
                root.hasError = true
                root.errorMessage = "Rate limit exceeded. Add a GitHub token in settings."
                ToastService.showError("GitHub Feed", "API rate limit exceeded. Please add a Personal Access Token in settings.")
            } else if (msg.indexOf("Not Found") !== -1) {
                root.hasError = true
                root.errorMessage = "User not found: " + root.username
            } else {
                root.hasError = true
                root.errorMessage = msg
            }
            return true
        }
        return false
    }

    Process {
        id: followingProcess

        command: root.username ? buildCurlCommand("https://api.github.com/users/" + root.username.trim() + "/following?per_page=100") : ["echo", ""]

        stdout: StdioCollector {
            onStreamFinished: {
                handleFollowingResponse(this.text)
            }
        }

        stderr: StdioCollector {}
    }

    property var receivedEventsPages: []
    property int currentReceivedEventsPage: 1
    readonly property int maxReceivedEventsPages: 3

    Process {
        id: receivedEventsProcess

        property int page: 1

        stdout: StdioCollector {
            onStreamFinished: {
                handleReceivedEventsResponse(this.text, receivedEventsProcess.page)
            }
        }

        stderr: StdioCollector {}
    }

    Process {
        id: userReposProcess

        command: root.username ? buildCurlCommand("https://api.github.com/users/" + root.username.trim() + "/repos?per_page=10&sort=updated") : ["echo", ""]

        stdout: StdioCollector {
            onStreamFinished: {
                handleUserReposResponse(this.text)
            }
        }

        stderr: StdioCollector {}
    }

    function fetchFromGitHub() {
        if (!root.username || root.username.trim() === "") {
            Logger.w("GitHubFeed", "No username configured")
            root.hasError = true
            root.errorMessage = "Please configure your GitHub username in settings"
            return
        }

        if (root.isLoading) {
            Logger.d("GitHubFeed", "Already fetching, skipping")
            return
        }

        Logger.i("GitHubFeed", "Fetching events for user:", root.username)
        root.isLoading = true
        root.hasError = false
        root.errorMessage = ""
        root.receivedEvents = []
        root.receivedEventsPages = []
        root.myRepoEvents = []
        root.userRepos = []
        root.currentReceivedEventsPage = 1
        root.pendingFetches = 3

        followingProcess.running = true
        receivedEventsProcess.page = 1
        receivedEventsProcess.command = buildCurlCommand("https://api.github.com/users/" + root.username.trim() + "/received_events?per_page=100&page=1")
        receivedEventsProcess.running = true
        userReposProcess.running = true
    }

    function handleFollowingResponse(responseText) {
        root.pendingFetches--

        if (!responseText || responseText.trim() === "") {
            Logger.w("GitHubFeed", "Empty following response")
            checkAllFetchesComplete()
            return
        }

        try {
            var data = JSON.parse(responseText)

            if (handleApiError(data, "Following")) {
                checkAllFetchesComplete()
                return
            }

            if (!Array.isArray(data)) {
                Logger.e("GitHubFeed", "Expected array for following")
                checkAllFetchesComplete()
                return
            }

            root.followingList = data.map(function(user) {
                return user.login.toLowerCase()
            })

            Logger.i("GitHubFeed", "Fetched " + root.followingList.length + " following")
            checkAllFetchesComplete()
        } catch (e) {
            Logger.e("GitHubFeed", "JSON parse error for following:", e)
            checkAllFetchesComplete()
        }
    }

    function handleReceivedEventsResponse(responseText, page) {
        if (!responseText || responseText.trim() === "") {
            Logger.w("GitHubFeed", "Empty received_events response for page " + page)
            root.pendingFetches--
            checkAllFetchesComplete()
            return
        }

        try {
            var data = JSON.parse(responseText)

            if (handleApiError(data, "Received events")) {
                root.pendingFetches--
                checkAllFetchesComplete()
                return
            }

            if (!Array.isArray(data)) {
                Logger.e("GitHubFeed", "Expected array for received_events")
                root.pendingFetches--
                checkAllFetchesComplete()
                return
            }

            root.receivedEventsPages = root.receivedEventsPages.concat(data)
            Logger.i("GitHubFeed", "Fetched page " + page + ": " + data.length + " events (total: " + root.receivedEventsPages.length + ")")

            if (page < root.maxReceivedEventsPages && data.length > 0) {
                root.currentReceivedEventsPage = page + 1
                receivedEventsProcess.page = page + 1
                receivedEventsProcess.command = buildCurlCommand("https://api.github.com/users/" + root.username.trim() + "/received_events?per_page=100&page=" + (page + 1))
                receivedEventsProcess.running = true
            } else {
                root.receivedEvents = root.receivedEventsPages
                Logger.i("GitHubFeed", "All received_events pages fetched, total: " + root.receivedEvents.length)
                root.pendingFetches--
                checkAllFetchesComplete()
            }
        } catch (e) {
            Logger.e("GitHubFeed", "JSON parse error for received_events:", e)
            root.pendingFetches--
            checkAllFetchesComplete()
        }
    }

    function handleUserReposResponse(responseText) {
        root.pendingFetches--

        if (!responseText || responseText.trim() === "") {
            Logger.w("GitHubFeed", "Empty user repos response")
            checkAllFetchesComplete()
            return
        }

        try {
            var data = JSON.parse(responseText)

            if (handleApiError(data, "User repos")) {
                checkAllFetchesComplete()
                return
            }

            if (!Array.isArray(data)) {
                Logger.e("GitHubFeed", "Expected array for user repos")
                checkAllFetchesComplete()
                return
            }

            root.userRepos = data
            Logger.i("GitHubFeed", "Fetched " + data.length + " user repos")

            if (data.length > 0) {
                fetchMyRepoEvents()
            } else {
                checkAllFetchesComplete()
            }
        } catch (e) {
            Logger.e("GitHubFeed", "JSON parse error for user repos:", e)
            checkAllFetchesComplete()
        }
    }

    property int pendingRepoEventFetches: 0
    property var repoEventQueue: []

    function fetchMyRepoEvents() {
        var reposToFetch = Math.min(root.userRepos.length, 5)
        root.pendingRepoEventFetches = reposToFetch
        root.repoEventQueue = []

        for (var i = 0; i < reposToFetch; i++) {
            root.repoEventQueue.push(root.userRepos[i].full_name)
        }

        fetchNextRepoEvents()
    }

    function fetchNextRepoEvents() {
        if (root.repoEventQueue.length === 0) {
            return
        }

        var repoName = root.repoEventQueue.shift()
        repoEventsProcess.repoName = repoName
        repoEventsProcess.command = buildCurlCommand("https://api.github.com/repos/" + repoName + "/events?per_page=30")
        repoEventsProcess.running = true
    }

    Process {
        id: repoEventsProcess
        property string repoName: ""

        stdout: StdioCollector {
            onStreamFinished: {
                handleRepoEventsResponse(this.text, repoEventsProcess.repoName)
            }
        }

        stderr: StdioCollector {}

        onExited: function(exitCode, exitStatus) {
            root.pendingRepoEventFetches--

            if (root.repoEventQueue.length > 0) {
                fetchNextRepoEvents()
            } else if (root.pendingRepoEventFetches <= 0) {
                checkAllFetchesComplete()
            }
        }
    }

    function handleRepoEventsResponse(responseText, repoName) {
        if (!responseText || responseText.trim() === "") {
            return
        }

        try {
            var data = JSON.parse(responseText)

            if (Array.isArray(data)) {
                var starForkEvents = data.filter(function(event) {
                    if (event.actor && event.actor.login.toLowerCase() === root.username.toLowerCase()) {
                        return false
                    }
                    return event.type === "WatchEvent" || event.type === "ForkEvent"
                })

                starForkEvents.forEach(function(event) {
                    event.isMyRepoEvent = true
                    event.myRepoName = repoName
                })

                root.myRepoEvents = root.myRepoEvents.concat(starForkEvents)
                Logger.d("GitHubFeed", "Found " + starForkEvents.length + " star/fork events on " + repoName)
            }
        } catch (e) {
            Logger.w("GitHubFeed", "Failed to parse repo events for " + repoName + ":", e)
        }
    }

    function checkAllFetchesComplete() {
        if (root.pendingFetches > 0 || root.pendingRepoEventFetches > 0) {
            return
        }

        finalizeFetch()
    }

    function finalizeFetch() {
        var followingSet = {}
        for (var i = 0; i < root.followingList.length; i++) {
            followingSet[root.followingList[i]] = true
        }

        var filteredReceivedEvents = root.receivedEvents.filter(function(event) {
            if (!event.actor || !event.actor.login) {
                return false
            }
            var actorLogin = event.actor.login.toLowerCase()
            return followingSet[actorLogin] === true
        })

        Logger.i("GitHubFeed", "Filtered to " + filteredReceivedEvents.length + " events from followed users (from " + root.receivedEvents.length + " total)")

        var allEvents = filteredReceivedEvents.concat(root.myRepoEvents)

        allEvents.sort(function(a, b) {
            var dateA = new Date(a.created_at)
            var dateB = new Date(b.created_at)
            return dateB - dateA
        })

        var seen = {}
        var uniqueEvents = []
        for (var j = 0; j < allEvents.length; j++) {
            var event = allEvents[j]
            if (!seen[event.id]) {
                seen[event.id] = true
                uniqueEvents.push(event)
            }
        }

        root.rawEvents = uniqueEvents
        root.lastFetchTimestamp = Math.floor(Date.now() / 1000)
        root.isLoading = false
        root.hasError = false

        Logger.i("GitHubFeed", "Raw events: " + root.rawEvents.length + ", Filtered: " + root.events.length)

        saveToCache()
        downloadAvatars(root.rawEvents)
    }

    property var pendingAvatars: []
    property bool isDownloadingAvatar: false

    Process {
        id: avatarDownloadProcess

        property string currentUserId: ""
        property string currentUrl: ""

        stdout: StdioCollector {}
        stderr: StdioCollector {}

        onExited: function(exitCode, exitStatus) {
            if (exitCode === 0) {
                var newAvatars = root.availableAvatars
                newAvatars[currentUserId] = true
                root.availableAvatars = newAvatars
                Logger.d("GitHubFeed", "Avatar downloaded for user:", currentUserId)
            }
            root.isDownloadingAvatar = false
            downloadNextAvatar()
        }
    }

    function downloadAvatars(events) {
        var seenUsers = {}

        for (var i = 0; i < events.length; i++) {
            var event = events[i]
            if (event.actor && event.actor.id && event.actor.avatar_url) {
                var userId = String(event.actor.id)
                if (!seenUsers[userId]) {
                    seenUsers[userId] = true
                    root.pendingAvatars.push({
                        id: userId,
                        url: event.actor.avatar_url
                    })
                }
            }
        }

        if (!root.isDownloadingAvatar) {
            downloadNextAvatar()
        }
    }

    function downloadNextAvatar() {
        if (root.pendingAvatars.length === 0) {
            return
        }

        var avatar = root.pendingAvatars.shift()
        var avatarPath = root.avatarsDir + "/" + avatar.id + ".png"

        avatarCheckProcess.avatarId = avatar.id
        avatarCheckProcess.avatarUrl = avatar.url
        avatarCheckProcess.avatarPath = avatarPath
        avatarCheckProcess.command = ["test", "-f", avatarPath]
        avatarCheckProcess.running = true
    }

    Process {
        id: avatarCheckProcess

        property string avatarId: ""
        property string avatarUrl: ""
        property string avatarPath: ""

        onExited: function(exitCode, exitStatus) {
            if (exitCode === 0) {
                var newAvatars = root.availableAvatars
                newAvatars[avatarId] = true
                root.availableAvatars = newAvatars
                downloadNextAvatar()
            } else {
                root.isDownloadingAvatar = true
                avatarDownloadProcess.currentUserId = avatarId
                avatarDownloadProcess.currentUrl = avatarUrl
                avatarDownloadProcess.command = [
                    "curl", "-s", "-L",
                    "-o", avatarPath,
                    avatarUrl + "&s=80"
                ]
                avatarDownloadProcess.running = true
            }
        }
    }

    function getAvatarPath(actorId) {
        if (!actorId) return ""
        var id = String(actorId)
        if (!root.availableAvatars[id]) return ""
        return "file://" + root.avatarsDir + "/" + id + ".png"
    }

    Timer {
        id: refreshTimer
        interval: root.refreshInterval * 1000
        running: root.username !== ""
        repeat: true
        triggeredOnStart: false

        onTriggered: {
            Logger.d("GitHubFeed", "Timer triggered, checking if refresh needed")
            var now = Math.floor(Date.now() / 1000)
            var age = now - root.lastFetchTimestamp

            if (age >= root.refreshInterval) {
                fetchFromGitHub()
            }
        }
    }

    IpcHandler {
        target: "plugin:github-feed"

        function refresh() {
            Logger.i("GitHubFeed", "Manual refresh triggered via IPC")
            root.lastFetchTimestamp = 0
            fetchFromGitHub()
            ToastService.showNotice("Refreshing GitHub feed...")
        }

        function toggle() {
            if (pluginApi) {
                pluginApi.withCurrentScreen(function(screen) {
                    pluginApi.openPanel(screen)
                })
            }
        }

        function setUsername(newUsername) {
            if (pluginApi && newUsername) {
                pluginApi.pluginSettings.username = newUsername
                pluginApi.saveSettings()
                root.rawEvents = []
                root.followingList = []
                root.lastFetchTimestamp = 0
                fetchFromGitHub()
                ToastService.showNotice("GitHub username updated: " + newUsername)
            }
        }
    }

    Component.onCompleted: {
        Logger.i("GitHubFeed", "Main component initialized")

        if (!root.username) {
            Logger.w("GitHubFeed", "No username configured")
            return
        }

        ensureCacheDir.running = true
    }

    Process {
        id: ensureCacheDir
        command: ["mkdir", "-p", root.avatarsDir]

        onExited: function(exitCode, exitStatus) {
            if (exitCode === 0) {
                scanAvatarsProcess.running = true
            }
        }
    }

    Process {
        id: scanAvatarsProcess
        command: ["ls", "-1", root.avatarsDir]

        stdout: StdioCollector {
            onStreamFinished: {
                var files = this.text.trim().split("\n")
                var avatars = {}
                for (var i = 0; i < files.length; i++) {
                    var file = files[i]
                    if (file.endsWith(".png")) {
                        var id = file.replace(".png", "")
                        avatars[id] = true
                    }
                }
                root.availableAvatars = avatars
                Logger.d("GitHubFeed", "Scanned " + Object.keys(avatars).length + " existing avatars")
                eventsCacheFile.reload()
            }
        }

        stderr: StdioCollector {}

        onExited: function(exitCode, exitStatus) {
            if (exitCode !== 0) {
                eventsCacheFile.reload()
            }
        }
    }

    onUsernameChanged: {
        if (root.username) {
            Logger.i("GitHubFeed", "Username changed, fetching new data")
            root.rawEvents = []
            root.followingList = []
            root.lastFetchTimestamp = 0
            fetchFromGitHub()
        }
    }
}
