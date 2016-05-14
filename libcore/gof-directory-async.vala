/***
    Copyright (C) 2011 Marlin Developers
                  2015-2016 elementary LLC (http://launchpad.net/elementary) 

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.

    Author: ammonkey <am.monkeyd@gmail.com>
            Jeremy Wootten <jeremy@elementaryos.org>
***/

private HashTable<GLib.File,GOF.Directory.Async> directory_cache;
private Mutex dir_cache_lock;

public class GOF.Directory.Async : Object {
    public delegate void GOFFileLoadedFunc (GOF.File file);

    private uint load_timeout_id = 0;
    private const int ENUMERATE_TIMEOUT_SEC = 10;
    private const int QUERY_INFO_TIMEOUT_SEC = 15;

    public GLib.File location;
    public GLib.File? selected_file = null;
    public GOF.File file;
    public int icon_size = 32;

    /* we're looking for particular path keywords like *\/icons* .icons ... */
    public bool uri_contain_keypath_icons;

    /* for auto-sizing Miller columns */
    public string longest_file_name = "";
    public bool track_longest_name = false;

    public enum State {
        NOT_LOADED,
        LOADING,
        LOADED
    }
    public State state {get; private set;}

    private HashTable<GLib.File,GOF.File> file_hash;
    public uint files_count;

    public bool permission_denied = false;

    private Cancellable cancellable;
    private FileMonitor? monitor = null;
    private List<unowned GOF.File>? sorted_dirs = null;

    public signal void file_loaded (GOF.File file);
    public signal void file_added (GOF.File? file); /* null used to signal failed operation */
    public signal void file_changed (GOF.File file);
    public signal void file_deleted (GOF.File file);
    public signal void icon_changed (GOF.File file); /* Called directly by GOF.File - handled by AbstractDirectoryView
                                                        Gets emitted for any kind of file operation */
 
    public signal void done_loading ();
    public signal void thumbs_loaded ();
    public signal void need_reload (bool original_request);

    private uint idle_consume_changes_id = 0;
    private bool removed_from_cache;
    private bool monitor_blocked = false;

    private unowned string gio_attrs {
        get {
            if (scheme == "network" || scheme == "computer" || scheme == "smb")
                return "*";
            else
                return GOF.File.GIO_DEFAULT_ATTRIBUTES;
        }
    }

    public string scheme {get; private set;}
    public bool is_local {get; private set;}
    public bool is_trash {get; private set;}
    public bool is_network {get; private set;}
    public bool is_recent {get; private set;}
    public bool has_mounts {get; private set;}
    public bool has_trash_dirs {get; private set;}
    public bool can_load {get; private set;}
    public bool can_open_files {get; private set;}
    public bool can_stream_files {get; private set;}

    private bool is_ready = false;

    public bool is_cancelled {
        get { return cancellable.is_cancelled (); }
    }

    private Async (GLib.File _file) {
        /* Ensure uri is correctly escaped */
        location = GLib.File.new_for_uri (PF.FileUtils.escape_uri (_file.get_uri ()));
        file = GOF.File.get (location);

        cancellable = new Cancellable ();
        state = State.NOT_LOADED;
        can_load = false;

        scheme = location.get_uri_scheme ();
        is_trash = (scheme == "trash");
        is_recent = (scheme == "recent");
        is_local = is_trash || is_recent || (scheme == "file");
        is_network = !is_local && ("ftp sftp afp dav davs".contains (scheme));
        can_open_files = !("mtp".contains (scheme));
        can_stream_files = !("ftp sftp mtp dav davs".contains (scheme));

        dir_cache_lock.@lock (); /* will always have been created via call to public static functions from_file () or from_gfile () */
        directory_cache.insert (location.dup (), this);
        dir_cache_lock.unlock ();

        this.add_toggle_ref ((ToggleNotify) toggle_ref_notify);
        this.unref ();

        file_hash = new HashTable<GLib.File, GOF.File> (GLib.File.hash, GLib.File.equal);
    }

    ~Async () {
        debug ("Async destruct %s", file.uri);
        if (is_trash)
            disconnect_volume_monitor_signals ();
    }

    /** Views call the following function with null parameter - file_loaded and done_loading
      * signals are emitted and cause the view and view container to update.
      *
      * LocationBar calls this function, with a callback, on its own Async instances in order
      * to perform filename completion.- Emitting a done_loaded signal in that case would cause
      * the premature ending of text entry.
     **/
    public void init (GOFFileLoadedFunc? file_loaded_func = null) {
        if (state == State.LOADING) {
            return; /* Do not re-enter */
        }
        var previous_state = state;

        cancellable.cancel ();
        cancellable = new Cancellable ();

        /* If we already have a loaded file cache just list them */ 
        if (previous_state == State.LOADED) {
            list_cached_files (file_loaded_func);
        /* else fully initialise the directory */
        } else {
            state = State.LOADING;
            prepare_directory.begin (file_loaded_func);
        }
        /* done_loaded signal is emitted when ready */
    }

    /* This is also called when reloading the directory so that another attempt to connect to
     * the network is made
     */
    private async void prepare_directory (GOFFileLoadedFunc? file_loaded_func) {
        bool success = yield get_file_info ();
        if (success) {
            if (!file.is_folder () && !file.is_root_network_folder ()) {
                warning ("Trying to load a non-folder - finding parent");
                var parent = file.is_connected ? location.get_parent () : null;
                if (parent != null) {
                    file = GOF.File.get (parent);
                    selected_file = location.dup ();
                    location = parent;
                    success = yield get_file_info ();
                } else {
                    warning ("Parent is null for file %s", file.uri);
                    success = false;
                }
            } else {

            }
        } else {
            warning ("Failed to get file info for file %s", file.uri);
        }
        make_ready (success, file_loaded_func); /* Only place that should call this function */
    }

    private async bool get_file_info () {
        /* Force info to be refreshed - the GOF.File may have been created already by another part of the program
         * that did not ensure the correct info Aync purposes, and retrieved from cache (bug 1511307).
         */
        file.info = null;
        if (is_local) {
            return file.ensure_query_info ();
        }
        /* Must be non-local */
        if (is_network && !yield check_network ()) {
            file.is_connected = false;
            return false;
        } else {
            if (!yield try_query_info ()) { /* may already be mounted */
                if (yield mount_mountable ()) {
                /* Previously mounted Samba servers still appear mounted even if disconnected
                 * e.g. by unplugging the network cable.  So the following function can block for
                 * a long time; we therefore use a timeout */
                    debug ("successful mount %s", file.uri);
                    return yield try_query_info ();
                } else {
                    return false;
                }
            } else {
                return true;
            }
        }
    }

    private async bool try_query_info () {
        cancellable = new Cancellable ();
        bool querying = true;
        assert (load_timeout_id == 0);
        load_timeout_id = Timeout.add_seconds (QUERY_INFO_TIMEOUT_SEC, () => {
            if (querying) {
                warning ("Cancelled after timeout in query info async %s", file.uri);
                cancellable.cancel ();
                load_timeout_id = 0;
            }
            return false;
        });

        bool success = yield query_info_async (file, null, cancellable);
        querying = false;
        cancel_timeout (ref load_timeout_id);
        if (cancellable.is_cancelled ()) {
            warning ("Failed to get info - timed out and cancelled");
            file.is_connected = false;
            return false;
        }
        if (success) {
            debug ("got file info");
            file.update ();
            return true;
        } else {
            warning ("Failed to get file info for %s", file.uri);
            return false;
        }
    }

    private async bool mount_mountable () {
        try {
            var mount_op = new Gtk.MountOperation (null);
            yield location.mount_enclosing_volume (0, mount_op, cancellable);
            var mount = location.find_enclosing_mount ();
            debug ("Found enclosing mount %s", mount != null ? mount.get_name () : "null");
            return mount != null;
        } catch (Error e) {
            if (e is IOError.ALREADY_MOUNTED) {
                debug ("Already mounted %s", file.uri);
                file.is_connected = true;
            } else if (e is IOError.NOT_FOUND) {
                debug ("Enclosing mount not found %s (may be remote share)", file.uri);
                file.is_mounted = false;
                return true;
            } else {
                file.is_connected = false;
                file.is_mounted = false;
                warning ("Mount_mountable failed: %s", e.message);
                if (e is IOError.PERMISSION_DENIED || e is IOError.FAILED_HANDLED) {
                    permission_denied = true;
                }
            }
            return false;
        }
    }

    public async bool check_network () {
        var net_mon = GLib.NetworkMonitor.get_default ();
        var net_available = net_mon.get_network_available ();

        bool success = false;

        if (net_available) {
                SocketConnectable? connectable = null;
            if (!is_network) { /* e.g. smb://  */
                /* TODO:  Find a way of verifying samba server still connected;  gvfs does not detect
                 * when network connection is broken - still appears mounted and connected */
                success = true;
            } else {
                try {
                    connectable = NetworkAddress.parse_uri (file.uri, 21);
                    success = true;
                    /* Try to connect for real.  This should time out after about 15 seconds if
                     * the host is not reachable */
                    var scl = new SocketClient ();
                    var sc = yield scl.connect_async (connectable, cancellable);
                    success = (sc != null && sc.is_connected ());
                    debug ("Attempt to connect to %s %s", file.uri, success ? "succeeded" : "failed");
                }
                catch (GLib.Error e) {
                    warning ("Error connecting to connectable %s - %s", file.uri, e.message);
                }
            }
        } else {
            warning ("No network available");
        }
        return success;
    }
     

    private void make_ready (bool ready, GOFFileLoadedFunc? file_loaded_func = null) {
        can_load = ready;
        if (!can_load) {
            warning ("%s cannot load.  Connected %s, Mounted %s, Exists %s", file.uri,
                                                                             file.is_connected.to_string (),
                                                                             file.is_mounted.to_string (),
                                                                             file.exists.to_string ());
            state = State.NOT_LOADED; /* ensure state is correct */
            done_loading ();
            return;
        } else if (!is_ready) {
            uri_contain_keypath_icons = "/icons" in file.uri || "/.icons" in file.uri;
            if (file_loaded_func == null && is_local) {
                try {
                    monitor = location.monitor_directory (0);
                    monitor.rate_limit = 100;
                    monitor.changed.connect (directory_changed);
                } catch (IOError e) {
                    if (!(e is IOError.NOT_MOUNTED)) {
                        /* Will fail for remote filesystems - not an error */
                        debug ("directory monitor failed: %s %s", e.message, file.uri);
                    }
                }
            }

            set_confirm_trash ();
            file.mount = GOF.File.get_mount_at (location);
            if (file.mount != null) {
                file.is_mounted = true;
                unowned GLib.List? trash_dirs = null;
                trash_dirs = Marlin.FileOperations.get_trash_dirs_for_mount (file.mount);
                has_trash_dirs = (trash_dirs != null);
            } else {
                has_trash_dirs = is_local;
            }

            if (is_trash) {
                connect_volume_monitor_signals ();
            }

            is_ready = true;
        }
        /* May be loading for the first time or reloading after clearing directory info */
        list_directory_async.begin (file_loaded_func);
    }

    private void set_confirm_trash () {
        bool to_confirm = true;
        if (is_trash) {
            to_confirm = false;
            var mounts = VolumeMonitor.get ().get_mounts ();
            if (mounts != null) {
                foreach (GLib.Mount m in mounts) {
                    to_confirm |= (m.can_eject () && Marlin.FileOperations.has_trash_files (m));
                }
            }
        }
        Preferences.get_default ().confirm_trash = to_confirm;
    }

    private void connect_volume_monitor_signals () {
        var vm = VolumeMonitor.get();
        vm.mount_changed.connect (on_mount_changed);
        vm.mount_added.connect (on_mount_changed);
    }
    private void disconnect_volume_monitor_signals () {
        var vm = VolumeMonitor.get();
        vm.mount_changed.disconnect (on_mount_changed);
        vm.mount_added.disconnect (on_mount_changed);
    }

    private void on_mount_changed (GLib.VolumeMonitor vm, GLib.Mount mount) {
        if (state == State.LOADED) {
            need_reload (true);
        }
    }

    private static void toggle_ref_notify (void* data, Object object, bool is_last) {
        return_if_fail (object != null && object is Object);
        if (is_last) {
            Async dir = (Async) object;
            debug ("Async toggle_ref_notify %s", dir.file.uri);

            if (!dir.removed_from_cache)
                dir.remove_dir_from_cache ();

            dir.remove_toggle_ref ((ToggleNotify) toggle_ref_notify);
        }
    }

    public void cancel () {
        /* This should only be called when closing the view - it will cancel initialisation of the directory */
        cancellable.cancel ();
        cancel_timeouts ();
    }

    public void cancel_thumbnailing () {
        /* remove any pending thumbnail generation */
        cancel_timeout (ref timeout_thumbsq);
    }

    public void reload () {
        clear_directory_info ();
        init ();
    }

    /** Called in preparation for a reload **/
    private void clear_directory_info () {
        if (state == State.LOADING) {
            return; /* Do not re-enter */
        }
        cancel ();
        file_hash.remove_all ();
        monitor = null;
        sorted_dirs = null;
        files_count = 0;
        state = State.NOT_LOADED;
    }

    private void list_cached_files (GOFFileLoadedFunc? file_loaded_func = null) {
        if (state != State.LOADED) {
            warning ("list cached files called in %s state - not expected to happen", state.to_string ());
            return;
        }
        state = State.LOADING;
        bool show_hidden = is_trash || Preferences.get_default ().pref_show_hidden_files;
        foreach (GOF.File gof in file_hash.get_values ()) {
            if (gof != null) {
                after_load_file (gof, show_hidden, file_loaded_func);
            }
        }
        state = State.LOADED;
        after_loading (file_loaded_func);
    }

    private async void list_directory_async (GOFFileLoadedFunc? file_loaded_func) {
        /* Should only be called after creation and if reloaded */
        if (!is_ready || file_hash.size () > 0) {
            critical ("(Re)load directory called when not cleared");
            return;
        }

        if (!can_load) {
            warning ("load called when cannot load - not expected to happen");
            return;
        }

        if (state == State.LOADED) {
            warning ("load called when already loaded - not expected to happen");
            return;
        }
        if (load_timeout_id > 0) {
            warning ("load called when timeout already running - not expected to happen");
            return;
        }

        cancellable = new Cancellable ();
        longest_file_name = "";
        permission_denied = false;
        can_load = true;
        files_count = 0;
        state = State.LOADING;
        bool show_hidden = is_trash || Preferences.get_default ().pref_show_hidden_files;

        try {
            /* This may hang for a long time if the connection was closed but is still mounted so we
             * impose a time limit */
            load_timeout_id = Timeout.add_seconds (ENUMERATE_TIMEOUT_SEC, () => {
                cancellable.cancel ();
                load_timeout_id = 0;
                return false;
            });

            var e = yield this.location.enumerate_children_async (gio_attrs, 0, Priority.HIGH, cancellable);
            cancel_timeout (ref load_timeout_id);

            GOF.File? gof;
            GLib.File loc;
            while (!cancellable.is_cancelled ()) {
                var files = yield e.next_files_async (200, 0, cancellable);
                if (files == null) {
                    break;
                } else {
                    foreach (var file_info in files) {
                        loc = location.get_child (file_info.get_name ());
                        assert (loc != null);
                        gof = GOF.File.cache_lookup (loc);

                        if (gof == null) {
                            gof = new GOF.File (loc, location); /*does not add to GOF file cache */
                        }
                        gof.info = file_info;
                        gof.update ();

                        file_hash.insert (gof.location, gof);
                        after_load_file (gof, show_hidden, file_loaded_func);
                        files_count++;
                    }
                }
            }
            state = State.LOADED;
        } catch (Error err) {
            warning ("Listing directory error: %s %s", err.message, file.uri);
            can_load = false;
            if (err is IOError.NOT_FOUND || err is IOError.NOT_DIRECTORY) {
                file.exists = false;
            } else if (err is IOError.PERMISSION_DENIED)
                permission_denied = true;
            else if (err is IOError.NOT_MOUNTED)
                file.is_mounted = false;
        }

        after_loading (file_loaded_func);
    }

    private void after_load_file (GOF.File gof, bool show_hidden, GOFFileLoadedFunc? file_loaded_func) {
        if (!gof.is_hidden || show_hidden) {
            if (track_longest_name)
                update_longest_file_name (gof);

            if (file_loaded_func == null) {
                file_loaded (gof);
            } else
                file_loaded_func (gof);
        }
    }

    private void after_loading (GOFFileLoadedFunc? file_loaded_func) {
        /* If loading failed reset */
        debug ("after loading state is %s", state.to_string ());
        if (state == State.LOADING) {
            state = State.NOT_LOADED; /* else clear directory info will fail */
            clear_directory_info ();
            can_load = false;
        }
        if (file_loaded_func == null) {
            done_loading ();
        }
    }

    public void block_monitor () {
        if (monitor != null && !monitor_blocked) {
            monitor_blocked = true;
            monitor.changed.disconnect (directory_changed);
        }
    }

    public void unblock_monitor () {
        if (monitor != null && monitor_blocked) {
            monitor_blocked = false;
            monitor.changed.connect (directory_changed);
        }
    }

    private void update_longest_file_name (GOF.File gof) {
        if (longest_file_name.length < gof.basename.length)
            longest_file_name = gof.basename;
    }

    public void load_hiddens () {
        if (!can_load) {
            return;
        }
        if (state != State.LOADED) {
            list_directory_async.begin (null);
        } else {
            list_cached_files ();
        }
    }

    public void update_files () {
        foreach (GOF.File gof in file_hash.get_values ()) {
            if (gof != null && gof.info != null
                && (!gof.is_hidden || Preferences.get_default ().pref_show_hidden_files))

                gof.update ();
        }
    }

    public void update_desktop_files () {
        foreach (GOF.File gof in file_hash.get_values ()) {
            if (gof != null && gof.info != null
                && (!gof.is_hidden || Preferences.get_default ().pref_show_hidden_files)
                && gof.is_desktop)

                gof.update_desktop_file ();
        }
    }

    public GOF.File? file_hash_lookup_location (GLib.File? location) {
        if (location != null && location is GLib.File) {
            GOF.File? result = file_hash.lookup (location);
            /* Although file_hash.lookup returns an unowned value, Vala will add a reference
             * as the return value is owned.  This matches the behaviour of GOF.File.cache_lookup */ 
            return result;
        } else {
            return null;
        }
    }

    public void file_hash_add_file (GOF.File gof) { /* called directly by GOF.File */
        file_hash.insert (gof.location, gof); 
    }

    public GOF.File file_cache_find_or_insert (GLib.File file, bool update_hash = false) {
        assert (file != null);
        GOF.File? result = file_hash.lookup (file);
        /* Although file_hash.lookup returns an unowned value, Vala will add a reference
         * as the return value is owned.  This matches the behaviour of GOF.File.cache_lookup */ 
        if (result == null) {
            result = GOF.File.cache_lookup (file);

            if (result == null) {
                result = new GOF.File (file, location);
                file_hash.insert (file, result);
            }
            else if (update_hash)
                file_hash.insert (file, result);
        }

        return (!) result;
    }

    /**TODO** move this to GOF.File */
    private delegate void func_query_info (GOF.File gof);

    private async bool query_info_async (GOF.File gof, func_query_info? f = null, Cancellable? cancellable = null) {
        gof.info = null;
        try {
            gof.info = yield gof.location.query_info_async (gio_attrs,
                                                            FileQueryInfoFlags.NONE,
                                                            Priority.DEFAULT,
                                                            cancellable);
            if (f != null) {
                f (gof);
            }
        } catch (Error err) {
            warning ("query info failed, %s %s", err.message, gof.uri);
            if (err is IOError.NOT_FOUND) {
                gof.exists = false;
            }
        }
        return gof.info != null;
    }

    private void changed_and_refresh (GOF.File gof) {
        if (gof.is_gone) {
            warning ("File marked as gone when refreshing change");
            return;
        }

        gof.update ();

        if (!gof.is_hidden || Preferences.get_default ().pref_show_hidden_files) {
            file_changed (gof);
            gof.changed ();
        }
    }

    private void add_and_refresh (GOF.File gof) {
        if (gof.is_gone) {
            warning ("Add and refresh file which is gone");
            return;
        }
        if (gof.info == null)
            critical ("FILE INFO null");

        gof.update ();

        if ((!gof.is_hidden || Preferences.get_default ().pref_show_hidden_files))
            file_added (gof);

        if (!gof.is_hidden && gof.is_folder ()) {
            /* add to sorted_dirs */
            if (sorted_dirs.find (gof) == null)
                sorted_dirs.insert_sorted (gof,
                    GOF.File.compare_by_display_name);
        }

        if (track_longest_name && gof.basename.length > longest_file_name.length) {
            longest_file_name = gof.basename;
            done_loading ();
        }
    }

    private void notify_file_changed (GOF.File gof) {
        query_info_async.begin (gof, changed_and_refresh);
    }

    private void notify_file_added (GOF.File gof) {
        query_info_async.begin (gof, add_and_refresh);
    }

    private void notify_file_removed (GOF.File gof) {
        if (!gof.is_hidden || Preferences.get_default ().pref_show_hidden_files)
            file_deleted (gof);

        if (!gof.is_hidden && gof.is_folder ()) {
            /* remove from sorted_dirs */

            /* Addendum note: GLib.List.remove() does not unreference objects.
               See: https://bugzilla.gnome.org/show_bug.cgi?id=624249
                    https://bugzilla.gnome.org/show_bug.cgi?id=532268

               The declaration of sorted_dirs has been changed to contain
               weak pointers as a temporary solution. */
            sorted_dirs.remove (gof);
        }

        gof.remove_from_caches ();
    }

    private struct fchanges {
        GLib.File           file;
        FileMonitorEvent    event;
    }
    private List <fchanges?> list_fchanges = null;
    private uint list_fchanges_count = 0;
    /* number of monitored changes to store after that simply reload the dir */
    private const uint FCHANGES_MAX = 20;

    private void directory_changed (GLib.File _file, GLib.File? other_file, FileMonitorEvent event) {
        /* If view is frozen, store events for processing later */
        if (freeze_update) {
            if (list_fchanges_count < FCHANGES_MAX) {
                var fc = fchanges ();
                fc.file = _file;
                fc.event = event;
                list_fchanges.prepend (fc);
                list_fchanges_count++;
            }
            return;
        } else
            real_directory_changed (_file, other_file, event);
    }

    private void real_directory_changed (GLib.File _file, GLib.File? other_file, FileMonitorEvent event) {
        switch (event) {
        case FileMonitorEvent.CREATED:
            MarlinFile.changes_queue_file_added (_file);
            break;
        case FileMonitorEvent.DELETED:
            MarlinFile.changes_queue_file_removed (_file);
            break;
        case FileMonitorEvent.CHANGES_DONE_HINT: /* test  last to avoid unnecessary action when file renamed */
        case FileMonitorEvent.ATTRIBUTE_CHANGED:
            MarlinFile.changes_queue_file_changed (_file);
            break;
        }

        if (idle_consume_changes_id == 0) {
            /* Insert delay to avoid race between gof.rename () finishing and consume changes -
             * If consume changes called too soon can corrupt the view.
             * TODO: Have GOF.Directory.Async control renaming.
             */
            idle_consume_changes_id = Timeout.add (10, () => {
                MarlinFile.changes_consume_changes (true);
                idle_consume_changes_id = 0;
                return false;
            });
        }
    }

    private bool _freeze_update;
    public bool freeze_update {
        get {
            return _freeze_update;
        }
        set {
            _freeze_update = value;

            if (!value) {
                if (list_fchanges_count >= FCHANGES_MAX) {
                    need_reload (true);
                } else if (list_fchanges_count > 0) {
                    list_fchanges.reverse ();
                    foreach (var fchange in list_fchanges) {
                        real_directory_changed (fchange.file, null, fchange.event);
                    }
                }
            }

            list_fchanges_count = 0;
            list_fchanges = null;
        }
    }

    public static void notify_files_changed (List<GLib.File> files) {
        foreach (var loc in files) {
            assert (loc != null);
            Async? parent_dir = cache_lookup_parent (loc);
            GOF.File? gof = null;
            if (parent_dir != null) {
                gof = parent_dir.file_cache_find_or_insert (loc);
                parent_dir.notify_file_changed (gof);
            }

            /* Has a background directory been changed (e.g. properties)? If so notify the view(s)*/
            Async? dir = cache_lookup (loc);
            if (dir != null) {
                dir.notify_file_changed (dir.file);
            }
        }
    }

    public static void notify_files_added (List<GLib.File> files) {
        foreach (var loc in files) {
            Async? dir = cache_lookup_parent (loc);

            if (dir != null) {
                GOF.File gof = dir.file_cache_find_or_insert (loc, true);
                dir.notify_file_added (gof);
            }
        }
    }

    public static void notify_files_removed (List<GLib.File> files) {
        List<Async> dirs = null;
        bool found;

        foreach (var loc in files) {
            assert (loc != null);
            Async? dir = cache_lookup_parent (loc);

            if (dir != null) {
                GOF.File gof = dir.file_cache_find_or_insert (loc);
                dir.notify_file_removed (gof);
                found = false;

                foreach (var d in dirs) {
                    if (d == dir)
                        found = true;
                }

                if (!found)
                    dirs.append (dir);
            } else {
                warning ("parent of deleted file not found");
            }
        }

        foreach (var d in dirs) {
            if (d.track_longest_name) {
                d.list_cached_files ();
            }
        }
    }

    public static void notify_files_moved (List<GLib.Array<GLib.File>> files) {
        List<GLib.File> list_from = new List<GLib.File> ();
        List<GLib.File> list_to = new List<GLib.File> ();

        foreach (var pair in files) {
            GLib.File from = pair.index (0);
            GLib.File to = pair.index (1);

            list_from.append (from);
            list_to.append (to);
        }

        notify_files_removed (list_from);
        notify_files_added (list_to);
    }

    public static Async from_gfile (GLib.File file) {
        assert (file != null);
        /* Note: cache_lookup creates directory_cache if necessary */
        Async?  dir = cache_lookup (file);
        /* Both local and non-local files can be cached */
        return dir ?? new Async (file);
    }

    public static Async from_file (GOF.File gof) {
        return from_gfile (gof.get_target_location ());
    }

    public static void remove_file_from_cache (GOF.File gof) {
        assert (gof != null);
        Async? dir = cache_lookup (gof.directory);
        if (dir != null)
            dir.file_hash.remove (gof.location);
    }

    public static Async? cache_lookup (GLib.File? file) {
        Async? cached_dir = null;

        if (directory_cache == null) {
            directory_cache = new HashTable<GLib.File,GOF.Directory.Async> (GLib.File.hash, GLib.File.equal);
            dir_cache_lock = GLib.Mutex ();
            return null;
        }

        if (file == null) {
            critical ("Null file received in Async cache_lookup");
        }
        dir_cache_lock.@lock ();
        cached_dir = directory_cache.lookup (file);

        if (cached_dir != null) {
            if (cached_dir is Async && cached_dir.file != null) {
                debug ("found cached dir %s", cached_dir.file.uri);
                if (cached_dir.file.info == null)
                    cached_dir.file.query_update ();
            } else {
                warning ("Invalid directory found in cache");
                cached_dir = null;
                directory_cache.remove (file);
            }
        } else {
            debug ("Dir %s not in cache", file.get_uri ());
        }
        dir_cache_lock.unlock ();

        return cached_dir;
    }

    public static Async? cache_lookup_parent (GLib.File file) {
        if (file == null) {
            warning ("Null file submitted to cache lookup parent");
            return null;
        }
        GLib.File? parent = file.get_parent ();
        return parent != null ? cache_lookup (parent) : cache_lookup (file);
    }

    public bool remove_dir_from_cache () {
        /* we got to increment the dir ref to remove the toggle_ref */
        this.ref ();

        removed_from_cache = true;
        return directory_cache.remove (location);
    }

    public bool purge_dir_from_cache () {
        var removed = remove_dir_from_cache ();
        /* We have to remove the dir's subfolders from cache too */
        if (removed) {
            foreach (var gfile in file_hash.get_keys ()) {
                assert (gfile != null);
                var dir = cache_lookup (gfile);
                if (dir != null)
                    dir.remove_dir_from_cache ();
            }
        }

        return removed;
    }

    public bool has_parent () {
        return (file.directory != null);
    }

    public GLib.File get_parent () {
        return file.directory;
    }

    public bool is_loading () {
        return this.state == State.LOADING;
    }

    public bool is_loaded () {
        return this.state == State.LOADED;
    }

    public bool is_empty () {
        return (state == State.LOADED && file_hash.size () == 0); /* only return true when loaded to avoid temporary appearance of empty message while loading */
    }

    public unowned List<GOF.File>? get_sorted_dirs () {
        if (state != State.LOADED) { /* Can happen if pathbar tries to load unloadable directory */
            return null;
        }

        if (sorted_dirs != null)
            return sorted_dirs;

        foreach (var gof in file_hash.get_values()) { /* returns owned values */
            if (!gof.is_hidden && (gof.is_folder () || gof.is_smb_server ())) {
                sorted_dirs.prepend (gof);
            }
        }

        sorted_dirs.sort (GOF.File.compare_by_display_name);
        return sorted_dirs;
    }

    /* Thumbnail loading */
    private uint timeout_thumbsq = 0;
    private bool thumbs_stop;
    private bool thumbs_thread_running;

    private void *load_thumbnails_func () {
        return_val_if_fail (this is Async, null);
        /* Ensure only one thread loading thumbs for this directory */
        return_val_if_fail (!thumbs_thread_running, null);

        if (cancellable.is_cancelled () || file_hash == null) {
            this.unref ();
            return null;
        }
        thumbs_thread_running = true;
        thumbs_stop = false;

        GLib.List<unowned GOF.File> files = file_hash.get_values ();
        foreach (var gof in files) {
            if (cancellable.is_cancelled () || thumbs_stop)
                break;

            /* Only try to load pixbuf from thumbnail if one may exist.
             * Note: query_thumbnail_update () does not call the thumbnailer, only loads pixbuf from existing thumbnail file.*/
            if (gof.flags != GOF.File.ThumbState.NONE) {
                gof.pix_size = icon_size;
                gof.query_thumbnail_update ();
            }
        }

        if (!cancellable.is_cancelled () && !thumbs_stop)
            thumbs_loaded ();

        thumbs_thread_running = false;
        this.unref ();
        return null;
    }

    private void threaded_load_thumbnails (int size) {
        try {
            icon_size = size;
            thumbs_stop = false;
            this.ref ();
            new Thread<void*>.try ("load_thumbnails_func", load_thumbnails_func);
        } catch (Error e) {
            critical ("Could not start loading thumbnails: %s", e.message);
        }
    }

    private bool queue_thumbs_timeout_cb () {
        /* Wait for thumbnail thread to stop then start a new thread */
        if (!thumbs_thread_running) {
            threaded_load_thumbnails (icon_size);
            timeout_thumbsq = 0;
            return false;
        }

        return true;
    }

    public void queue_load_thumbnails (int size) {
        if (!is_local)
            return;

        icon_size = size;
        if (this.state == State.LOADING)
            return;

        /* Do not interrupt loading thumbs at same size for this folder */
        if ((icon_size == size) && thumbs_thread_running)
            return;

        icon_size = size;
        thumbs_stop = true;

        /* Wait for thumbnail thread to stop then start a new thread */
        if (timeout_thumbsq != 0)
            GLib.Source.remove (timeout_thumbsq);

        timeout_thumbsq = Timeout.add (40, queue_thumbs_timeout_cb);
    }

    private void cancel_timeouts () {
        cancel_timeout (ref timeout_thumbsq);
        cancel_timeout (ref idle_consume_changes_id);
        cancel_timeout (ref load_timeout_id);
        
    }

    private bool cancel_timeout (ref uint id) {
        if (id > 0) {
            Source.remove (id);
            id = 0;
            return true;
        } else {
            return false;
        }
    }
}
