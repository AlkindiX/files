/***
    Copyright (c) 2015-2016 elementary LLC (http://launchpad.net/elementary)

    This program is free software: you can redistribute it and/or modify it
    under the terms of the GNU Lesser General Public License version 3, as published
    by the Free Software Foundation.

    This program is distributed in the hope that it will be useful, but
    WITHOUT ANY WARRANTY; without even the implied warranties of
    MERCHANTABILITY, SATISFACTORY QUALITY, or FITNESS FOR A PARTICULAR
    PURPOSE. See the GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along
    with this program. If not, see <http://www.gnu.org/licenses/>.

    Authors :
***/

namespace Marlin.View.Chrome
{
    public class SearchResults : Gtk.Window, Searchable
    {
        class Match : Object
        {
            public string name { get; construct; }
            public string mime { get; construct; }
            public string path_string { get; construct; }
            public Icon icon { get; construct; }
            public File? file { get; construct; }

            public Match (FileInfo info, string path_string, File parent)
            {
                Object (name: info.get_display_name (),
                        mime: info.get_content_type (),
                        icon: info.get_icon (),
                        path_string: path_string,
                        file: parent.resolve_relative_path (info.get_name ()));
            }

            public Match.from_bookmark (Bookmark bookmark)
            {
                Object (name: bookmark.label,
                        mime: "inode/directory",
                        icon: bookmark.get_icon (),
                        path_string: "",
                        file: bookmark.get_location ());
            }

            public Match.ellipsis ()
            {
                Object (name: "...",
                        mime: "",
                        icon: null,
                        path_string: "",
                        file: null);
            }
        }

        const int MAX_RESULTS = 10;
        const int MAX_DEPTH = 5;
        const int DELAY_ADDING_RESULTS = 150;

        private new Gtk.Widget parent;
        protected bool working { get; private set; default = false; }
        protected int n_results { get; private set; default = 0; }

        File current_root;
        string search_term = "";
        Gee.Queue<File> directory_queue;
        ulong waiting_handler;

        uint adding_timeout;
        bool allow_adding_results = false;
        Gee.Map<Gtk.TreeIter?,Gee.List> waiting_results;

        Cancellable? current_operation = null;
        Cancellable? file_search_operation = null;

        Zeitgeist.Index zg_index;
        GenericArray<Zeitgeist.Event> templates;

        int display_count;

        bool local_search_finished = false;
        bool global_search_finished = false;
        protected bool search_current_directory_only = false;
        protected bool begins_with_only = false;

        bool is_grabbing = false;
        Gdk.Device? device = null;

        Gtk.TreeIter local_results;
        Gtk.TreeIter global_results;
        Gtk.TreeIter bookmark_results;
        Gtk.TreeIter no_results_label;
        Gtk.TreeView view;
        Gtk.TreeStore list;
        Gtk.TreeModelFilter filter;
        Gtk.ScrolledWindow scroll;

        public SearchResults (Gtk.Widget parent_widget)
        {
            Object (resizable: false,
                    type_hint: Gdk.WindowTypeHint.COMBO,
                    type: Gtk.WindowType.POPUP);

            parent = parent_widget;
        }

        construct
        {
            var template = new Zeitgeist.Event ();

            var template_subject  = new Zeitgeist.Subject ();
            template_subject.manifestation = Zeitgeist.NFO.FILE_DATA_OBJECT;
            template.add_subject (template_subject);

            templates = new GenericArray<Zeitgeist.Event> ();
            templates.add (template);

            zg_index = new Zeitgeist.Index ();

            var frame = new Gtk.Frame (null);
            frame.shadow_type = Gtk.ShadowType.ETCHED_IN;

            scroll = new Gtk.ScrolledWindow (null, null);
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;

            view = new Gtk.TreeView ();
            view.get_selection ().set_mode (Gtk.SelectionMode.BROWSE);
            view.headers_visible = false;
            view.show_expanders = false;
            view.level_indentation = 12;
            view.set_hover_selection (true);

            get_style_context ().add_class ("completion-popup");

            var column = new Gtk.TreeViewColumn ();
            column.sizing = Gtk.TreeViewColumnSizing.FIXED;

            var cell = new Gtk.CellRendererPixbuf ();
            column.pack_start (cell, false);
            column.set_attributes (cell, "gicon", 1, "visible", 4);

            var cell_name = new Gtk.CellRendererText ();
            cell_name.ellipsize = Pango.EllipsizeMode.MIDDLE;
            column.pack_start (cell_name, true);
            column.set_attributes (cell_name, "markup", 0);

            var cell_path = new Gtk.CellRendererText ();
            cell_path.xpad = 6;
            cell_path.ellipsize = Pango.EllipsizeMode.MIDDLE;
            column.pack_start (cell_path, false);
            column.set_attributes (cell_path, "markup", 2);

            view.append_column (column);

            list = new Gtk.TreeStore (5, typeof (string), typeof (GLib.Icon),
                typeof (string), typeof (File), typeof (bool));
            filter = new Gtk.TreeModelFilter (list, null);
            filter.set_visible_func ((model, iter) => {
                if (iter == no_results_label)
                    return n_results < 1;

                /* hide empty category headers */
                return list.iter_depth (iter) != 0 || list.iter_has_child (iter);
            });
            view.model = filter;

            list.row_changed.connect ((path, iter) => {
                /* If the first match is in the current directory it will be selected */
                if (path.to_string () == "0:0") {
                    File? file;
                    list.@get (iter, 3, out file);
                    first_match_found (file);
                }
            });

            list.append (out local_results, null);
            list.@set (local_results, 0, get_category_header (_("In This Folder")));
            list.append (out bookmark_results, null);
            list.@set (bookmark_results, 0, get_category_header (_("Bookmarks")));
            list.append (out global_results, null);
            list.@set (global_results, 0, get_category_header (_("Everywhere Else")));

            scroll.add (view);
            frame.add (scroll);
            add (frame);

            button_press_event.connect (on_button_press_event);
            view.button_press_event.connect (on_view_button_press_event);
            key_press_event.connect (on_key_press_event);
        }

        /** Search interface functions **/
        public  void cancel () {
            /* popdown first to avoid unwanted cursor change signals */
            popdown ();
            if (current_operation != null) {
                current_operation.cancel ();
            }
            clear ();
        }

        public void search (string term, File folder)
        {
            device = Gtk.get_current_event_device ();
            search_term = term.normalize ().casefold ();

            if (device != null && device.input_source == Gdk.InputSource.KEYBOARD) {
                device = device.associated_device;
            }

            if (!current_operation.is_cancelled ()) {
                current_operation.cancel ();
            }

            if (adding_timeout != 0) {
                Source.remove (adding_timeout);
                adding_timeout = 0;
                allow_adding_results = true;

                /* we need to catch the case when we were only waiting for the timeout
                 * to be finished and the actual search was already done. Otherwise the next
                 * condition will never be reached.
                 */

                if (global_search_finished && local_search_finished) {
                    working = false;
                }
            }

            if (working) {
                if (waiting_handler != 0) {
                    SignalHandler.disconnect (this, waiting_handler);
                }
                waiting_handler = notify["working"].connect (() => {
                    SignalHandler.disconnect (this, waiting_handler);
                    waiting_handler = 0;
                    search (search_term, folder);
                });

                return;
            }

            var include_hidden = GOF.Preferences.get_default ().pref_show_hidden_files;

            display_count = 0;
            directory_queue = new Gee.LinkedList<File> ();
            waiting_results = new Gee.HashMap<Gtk.TreeIter?,Gee.List> ();
            current_root = folder;

            current_operation = new Cancellable ();
            file_search_operation = new Cancellable ();

            current_operation.cancelled.connect (file_search_operation.cancel);

            clear ();

            working = true;
            n_results = 0;

            directory_queue.add (folder);

            allow_adding_results = false;
            adding_timeout = Timeout.add (DELAY_ADDING_RESULTS, () => {
                adding_timeout = 0;
                allow_adding_results = true;

                var it = waiting_results.map_iterator ();

                while (it.next ())
                    add_results (it.get_value (), it.get_key ());

                send_search_finished ();
                return false;
            });

            new Thread<void*> (null, () => {
                local_search_finished = false;
                while (!file_search_operation.is_cancelled () && directory_queue.size > 0) {
                    visit (search_term, include_hidden, file_search_operation);
                }

                local_search_finished = true;
                Idle.add (send_search_finished);

                return null;
            });

            if (!search_current_directory_only) {
                get_zg_results.begin (search_term);

                var bookmarks_matched = new Gee.LinkedList<Match> ();

                foreach (var bookmark in BookmarkList.get_instance ().list) {
                    if (term_matches (search_term, bookmark.label)) {
                        bookmarks_matched.add (new Match.from_bookmark (bookmark));
                    }
                }

                add_results (bookmarks_matched, bookmark_results);
            } else {
                global_search_finished = true;
            }
        }

        public void set_search_current_directory_only (bool only) {
            search_current_directory_only = only;
        }
        public void set_begins_with_only (bool only) {
            begins_with_only = only;
        }

        /** Signal handlers **/
        void on_cursor_changed () {
            Gtk.TreeIter iter;
            Gtk.TreePath? path = null;
            var selected_paths = view.get_selection ().get_selected_rows (null);

            if (selected_paths != null)
                path = selected_paths.data;

            if (path != null) {
                filter.get_iter (out iter, path);
                filter.convert_iter_to_child_iter (out iter, iter);
                cursor_changed (get_file_at_iter (iter));
            }
        }

        bool on_button_press_event (Gdk.EventButton e) {
            if (e.x >= 0 && e.y >= 0 && e.x < get_allocated_width () && e.y < get_allocated_height ()) {
                view.event (e);
                return true;
            } else {
                cancel ();
                return false;
            }
        }

        bool on_view_button_press_event (Gdk.EventButton e) {
            Gtk.TreePath path;
            Gtk.TreeIter iter;

            view.get_path_at_pos ((int) e.x, (int) e.y, out path, null, null, null);

            if (path != null) {
                filter.get_iter (out iter, path);
                filter.convert_iter_to_child_iter (out iter, iter);
                accept (iter, e.button > 1);  /* This will call cancel () */
            }
            return true;
        }

        bool on_key_press_event (Gdk.EventKey event) {
            if (event.is_modifier == 1) {
                return true;
            }
            var mods = event.state & Gtk.accelerator_get_default_mod_mask ();
            bool only_control_pressed = (mods == Gdk.ModifierType.CONTROL_MASK);
            bool shift_pressed = ((mods & Gdk.ModifierType.SHIFT_MASK) != 0);
            bool alt_pressed = ((mods & Gdk.ModifierType.MOD1_MASK) != 0);
            bool only_shift_pressed = shift_pressed && ((mods & ~Gdk.ModifierType.SHIFT_MASK) == 0);
            bool only_alt_pressed = alt_pressed && ((mods & ~Gdk.ModifierType.MOD1_MASK) == 0);

            if (mods != 0 && !only_shift_pressed) {
                if (only_control_pressed) {
                    if (event.keyval == Gdk.Key.f) {
                        search_current_directory_only = false;
                        begins_with_only = false;
                        search (search_term, current_root);
                        return true;
                    } else if (event.keyval == Gdk.Key.l) {
                        cancel (); /* release any grab */
                        exit (false); /* Do not exit navigate mode */
                        return true;
                    } else {
                        return parent.key_press_event (event);
                    }
                } else if (only_alt_pressed &&
                           event.keyval == Gdk.Key.Return ||
                           event.keyval == Gdk.Key.KP_Enter ||
                           event.keyval == Gdk.Key.ISO_Enter) {

                    accept (null, true);
                } else {
                    return parent.key_press_event (event);
                }
            }
            switch (event.keyval) {
                case Gdk.Key.Return:
                case Gdk.Key.KP_Enter:
                case Gdk.Key.ISO_Enter:
                    accept ();
                    return true;
                case Gdk.Key.Up:
                case Gdk.Key.Down:
                    if (list_empty ()) {
                        Gdk.beep ();
                        return true;
                    }

                    var up = event.keyval == Gdk.Key.Up;

                    if (view.get_selection ().count_selected_rows () < 1) {
                        if (up)
                            select_last ();
                        else
                            select_first ();
                        return true;
                    }
                    select_adjacent (up);
                    return true;
                case Gdk.Key.Escape:
                    cancel (); /* release any grab */
                    exit ();
                    return true;
                default:
                    break;
            }
            return parent.key_press_event (event);
        }

        void select_first ()
        {
            Gtk.TreeIter iter;
            list.get_iter_first (out iter);

            do {
                if (!list.iter_has_child (iter))
                    continue;

                list.iter_nth_child (out iter, iter, 0);
                select_iter (iter);
                break;
            } while (list.iter_next (ref iter));

            /* make sure we actually scroll all the way back to the unselectable header */
            scroll.vadjustment.@value = 0;
        }

        void select_last ()
        {
            File file;
            Gtk.TreeIter iter;

            list.iter_nth_child (out iter, null, filter.iter_n_children (null) - 1);

            do {
                if (!list.iter_has_child (iter))
                    continue;

                list.iter_nth_child (out iter, iter, list.iter_n_children (iter) - 1);

                list.@get (iter, 3, out file);

                /* catch the case when we land on an ellipsis */
                if (file == null)
                    list.iter_previous (ref iter);

                select_iter (iter);
                break;
            } while (list.iter_previous (ref iter));
        }

        void select_adjacent (bool up)
        {
            File? file = null;
            Gtk.TreeIter iter, parent;
            get_iter_at_cursor (out iter);

            var valid = up ? list.iter_previous (ref iter) : list.iter_next (ref iter);

            if (valid) {
                list.@get (iter, 3, out file);
                if (file != null) {
                    select_iter (iter);
                    return;
                }
            }

            get_iter_at_cursor (out iter);
            list.iter_parent (out parent, iter);

            do {
                if (up ? !list.iter_previous (ref parent) : !list.iter_next (ref parent)) {
                    if (up)
                        select_last ();
                    else
                        select_first ();

                    return;
                }
            } while (!list.iter_has_child (parent));

            list.iter_nth_child (out iter, parent, up ? list.iter_n_children (parent) - 1 : 0);

            /* make sure we haven't hit an ellipsis */
            if (up) {
                list.@get (iter, 3, out file);
                if (file == null)
                    list.iter_previous (ref iter);
            }

            select_iter (iter);
        }

        bool list_empty ()
        {
            Gtk.TreeIter iter;
            for (var valid = list.get_iter_first (out iter); valid; valid = list.iter_next (ref iter)) {
                if (list.iter_has_child (iter))
                    return false;
            }

            return true;
        }

        int n_matches (out int n_headers = null)
        {
            var matches = 0;
            n_headers = 0;

            Gtk.TreeIter iter;
            for (var valid = list.get_iter_first (out iter); valid; valid = list.iter_next (ref iter)) {
                var n_children = list.iter_n_children (iter);
                if (n_children > 0)
                    n_headers++;

                matches += n_children;
            }

            return matches;
        }

        void resize_popup ()
        {
            var parent_window = parent.get_window ();
            if (parent_window == null)
                return;

            int x, y;
            Gtk.Allocation parent_alloc;

            parent_window.get_origin (out x, out y);
            parent.get_allocation (out parent_alloc);

            x += parent_alloc.x;
            y += parent_alloc.y;

            var screen = parent.get_screen ();
            var monitor = screen.get_monitor_at_window (parent_window);
            var workarea = screen.get_monitor_workarea (monitor);

            int cell_height, separator_height, items, headers;
            view.style_get ("vertical-separator", out separator_height);
            view.get_column (0).cell_get_size (null, null, null, null, out cell_height);
            items = n_matches (out headers);

            if (visible && items + headers <= 1 && !working) {
                hide ();
            } else if (!visible && items + headers > 1  && !working) {
                popup ();
            }

            int total = int.max ((items + headers), 2);
            var height = total * (cell_height + separator_height);
            if (x < workarea.x)
                x = workarea.x;
            else if (x + width_request > workarea.x + workarea.width)
                x = workarea.x + workarea.width - width_request;

            y += parent_alloc.height;

            if (y + height > workarea.y + workarea.height)
                height = workarea.y + workarea.height - y - 12;

            scroll.set_min_content_height (height);
            set_size_request (int.min (parent_alloc.width, workarea.width), height);
            move (x, y);
            resize (width_request, height_request);
        }

        bool get_iter_at_cursor (out Gtk.TreeIter iter)
        {
            Gtk.TreePath? path = null;
            Gtk.TreeIter filter_iter = Gtk.TreeIter ();
            iter = Gtk.TreeIter ();

            view.get_cursor (out path, null);

            if (path == null || !filter.get_iter (out filter_iter, path))
                return false;

            filter.convert_iter_to_child_iter (out iter, filter_iter);
            return true;
        }

        void select_iter (Gtk.TreeIter iter)
        {
            filter.convert_child_iter_to_iter (out iter, iter);

            var path = filter.get_path (iter);
            view.set_cursor (path, null, false);
        }

        void popup ()
        {
            if (get_mapped ()) {
                return;
            }

            set_screen (parent.get_screen ());
            show_all ();
            view.grab_focus ();

            /* Ensure device grab and ungrab are paired */
            if (!is_grabbing && device != null) {
                Gtk.device_grab_add (this, device, true);
                device.grab (get_window (), Gdk.GrabOwnership.WINDOW, true, Gdk.EventMask.BUTTON_PRESS_MASK
                    | Gdk.EventMask.BUTTON_RELEASE_MASK
                    | Gdk.EventMask.POINTER_MOTION_MASK,
                    null, Gdk.CURRENT_TIME);

                is_grabbing = true;
            }
            /* Paired with disconnect function in popdown () */
            connect_view_cursor_changed_signal ();
        }

        void popdown ()
        {
            /* Paired with connect function in popup () */
            disconnect_view_cursor_changed_signal ();
            if (is_grabbing) {
                if (device == null) {
                    /* 'device' can become null during searching for reasons as yet unidentified. This ensures
                     * that grab and ungrab are matched (else interface freezes after some searches)
                     */
                    device = Gtk.get_current_event_device ();
                    debug ("Reference to device was lost while grabbing - should not happen");
                }

                device.ungrab (Gdk.CURRENT_TIME);
                Gtk.device_grab_remove (this, device);
                is_grabbing = false;
            }

            hide ();
        }

        void add_results (Gee.List<Match> new_results, Gtk.TreeIter parent)
        {
            if (current_operation.is_cancelled ()) {
                return;
            }

            if (!allow_adding_results) {
                Gee.List list;

                if ((list = waiting_results.@get (parent)) == null) {
                    list = new Gee.LinkedList<Match> ();
                    waiting_results.@set (parent, list);
                }
                list.insert_all (list.size, new_results);
                return;
            }

            Gtk.TreeIter iter;
            File file;

            foreach (var match in new_results) {
                /* prevent results from showing in both global and local results */
                if (parent == global_results) {
                    var already_added = false;

                    for (var valid = list.iter_nth_child (out iter, local_results, 0); valid;
                        valid = list.iter_next (ref iter)) {

                        list.@get (iter, 3, out file);

                        if (file != null && match.file != null && file.equal (match.file)) {
                            already_added = true;
                            break;
                        }
                    }

                    if (already_added)
                        continue;
                } else if (parent == local_results) {
                    for (var valid = list.iter_nth_child (out iter, global_results, 0); valid;
                        valid = list.iter_next (ref iter)) {

                        list.@get (iter, 3, out file);

                        if (file != null && match.file != null && file.equal (match.file)) {
                            list.remove (ref iter);
                            break;
                        }
                    }
                }

                var location = "<span %s>%s</span>".printf (get_pango_grey_color_string (),
                    Markup.escape_text (match.path_string));

                list.append (out iter, parent);
                list.@set (iter, 0, Markup.escape_text (match.name), 1, match.icon, 2, location, 3, match.file, 4, true);
                n_results++;

                view.expand_all ();
            }

            if (!working) {
                resize_popup ();
            }
        }

        void accept (Gtk.TreeIter? accepted = null, bool activate = false)
        {
            if (list_empty ()) {
                Gdk.beep ();
                return;
            }

            bool valid_iter = true ;
            if (accepted == null)
                valid_iter = get_iter_at_cursor (out accepted);

            if (!valid_iter) {
                Gdk.beep ();
                return;
            }

            File? file = null;

            /* It is important that the next line is not put into an if clause.
             * For reasons unknown, doing so causes a segmentation fault on some systems but not
             * others.  Any changes to the format and content of the accept () function should be
             * carefully checked for stability on a range of systems which differ in architecture,
             * speed and configuration.
             */
            list.@get (accepted, 3, out file);

            if (file == null) {
                Gdk.beep ();
                return;
            }

            cancel ();
            if (activate) {
                file_activated (file);
            } else {
                file_selected (file);
            }
        }

        File? get_file_at_iter (Gtk.TreeIter? iter)
        {
            if (iter == null) {
                get_iter_at_cursor (out iter);
            }

            File? file = null;
            if (iter != null)
                list.@get (iter, 3, out file);

            return file;
        }

        protected void clear ()
        {
            /* Disconnect the cursor-changed signal so that it does not get emitted when entries removed
             * causing incorrect files to get selected in icon view */ 
            disconnect_view_cursor_changed_signal ();
            Gtk.TreeIter parent, iter;
            for (var valid = list.get_iter_first (out parent); valid; valid = list.iter_next (ref parent)) {
                if (!list.iter_nth_child (out iter, parent, 0))
                    continue;

                while (list.remove (ref iter));
            }

            resize_popup ();
            /* Reconnect signal */
            connect_view_cursor_changed_signal ();
        }



        bool send_search_finished ()
        {
            if (!local_search_finished || !global_search_finished || !allow_adding_results) {
                return false;
            }

            working = false;

            if (current_operation.is_cancelled ()) {
                return false;
            }

            filter.refilter ();

            if (local_search_finished && global_search_finished && list_empty ()) {
                view.get_selection ().unselect_all ();
                first_match_found (null);
            } else {
                select_first ();
            }

            if (local_search_finished && global_search_finished) {
                resize_popup ();
            }

            return false;
        }

        string ATTRIBUTES = FileAttribute.STANDARD_NAME + "," +
                            FileAttribute.STANDARD_DISPLAY_NAME + "," +
                            FileAttribute.STANDARD_CONTENT_TYPE + "," +
                            FileAttribute.STANDARD_IS_HIDDEN + "," +
                            FileAttribute.STANDARD_TYPE + "," +
                            FileAttribute.STANDARD_ICON;

        void visit (string term, bool include_hidden, Cancellable cancel)
        {

            FileEnumerator enumerator;
            var folder = directory_queue.poll ();

            if (folder == null) {
                return;
            }

            var depth = 0;

            File f = folder;
            var path_string = "";
            while (!f.equal (current_root)) {
                path_string = f.get_basename () + (path_string == "" ? "" : Path.DIR_SEPARATOR_S + path_string);
                f = f.get_parent ();
                depth++;
            }

            if ((search_current_directory_only && depth > 1) || depth > MAX_DEPTH) {
                return;
            }

            try {
                enumerator = folder.enumerate_children (ATTRIBUTES, 0, cancel);
            } catch (Error e) {
                return;
            }

            var new_results = new Gee.LinkedList<Match> ();

            FileInfo info = null;
            try {
                while (!cancel.is_cancelled () && (info = enumerator.next_file (null)) != null) {
                    if (info.get_is_hidden () && !include_hidden) {
                        continue;
                    }

                    if (info.get_file_type () == FileType.DIRECTORY && !search_current_directory_only) {
                        directory_queue.add (folder.resolve_relative_path (info.get_name ()));
                    }

                    if (term_matches (term, info.get_display_name ())) {
                        new_results.add (new Match (info, path_string, folder));
                    }
                }
            } catch (Error e) {warning ("Error enumerating in visit");}

            if (new_results.size < 1) {
                return;
            }

            if (!cancel.is_cancelled ()) {
                var new_count = display_count + new_results.size;
                if (new_count > MAX_RESULTS) {
                    cancel.cancel ();

                    var num_ok = MAX_RESULTS - display_count;
                    if (num_ok < new_results.size) {
                        var count = 0;
                        var it = new_results.iterator ();
                        while (it.next ()) {
                            count++;
                            if (count > num_ok)
                                it.remove ();
                        }
                    }

                    new_results.add (new Match.ellipsis ());

                    display_count = MAX_RESULTS;
                } else
                    display_count = new_count;

                /* use a closure here to get vala to pass the userdata that we actually want */
                Idle.add (() => {
                    add_results (new_results, local_results);
                    return false;
                });
            }
        }

        async void get_zg_results (string term)
        {
            global_search_finished = false;

            Zeitgeist.ResultSet results;
            try {
                results = yield zg_index.search (term,
                                                 new Zeitgeist.TimeRange.anytime (),
                                                 templates,
                                                 0, /* offset */
                                                 MAX_RESULTS + 1,
                                                 Zeitgeist.ResultType.MOST_POPULAR_SUBJECTS,
                                                 current_operation);
            } catch (IOError.CANCELLED e) {
                global_search_finished = true;
                Idle.add (send_search_finished);
                return;
            } catch (Error e) {
                warning ("Fetching results for term '%s' from zeitgeist failed: %s", term, e.message);
                global_search_finished = true;
                Idle.add (send_search_finished);
                return;
            }

            var i = 0;

            var matches = new Gee.LinkedList<Match> ();
            var home = File.new_for_path (Environment.get_home_dir ());
            while (results.has_next () && !current_operation.is_cancelled ()) {
                var result = results.next_value ();
                foreach (var subject in result.subjects.data) {
                    if (i == MAX_RESULTS) {
                        matches.add (new Match.ellipsis ());
                        break;
                    }

                    try {
                        var file = File.new_for_uri (subject.uri);
                        var path_string = "";
                        var parent = file;
                        while ((parent = parent.get_parent ()) != null) {
                            if (parent.equal (current_root))
                                break;

                            if (parent.equal (home)) {
                                path_string = "~/" + path_string;
                                break;
                            }

                            if (path_string == "")
                                path_string = parent.get_basename ();
                            else
                                path_string = parent.get_basename () + Path.DIR_SEPARATOR_S + path_string;
                        }

                        var info = yield file.query_info_async (ATTRIBUTES, 0, Priority.DEFAULT, current_operation);
                        matches.add (new Match (info, path_string, file.get_parent ()));

                        i++;
                    } catch (Error e) {}
                }
            }

            if (!current_operation.is_cancelled ())
                add_results (matches, global_results);

            global_search_finished = true;
            Idle.add (send_search_finished);
        }

        bool term_matches (string term, string name)
        {
            /**TODO** improve */

            /* term is assumed to be down */
            bool res;
            if (begins_with_only)
                res = name.normalize ().casefold ().has_prefix (term);
            else
                res = name.normalize ().casefold ().contains (term);

            return res;
        }

        string get_category_header (string title)
        {
            return "<span weight='bold' %s>%s</span>".printf (get_pango_grey_color_string (), title);
        }

        string get_pango_grey_color_string ()
        {
            Gdk.RGBA rgba;
            string color = "";
            var colored = get_style_context ().lookup_color ("placeholder_text_color", out rgba);

            if (colored) {
                Gdk.Color gdk_color = { 0, (uint16) (rgba.red * 65536), (uint16) (rgba.green * 65536), (uint16) (rgba.blue * 65536) };
                color = "color='%s'".printf (gdk_color.to_string ());
            }

            return color;
        }

        public bool has_popped_up () {
            return is_grabbing;
        }

        private void connect_view_cursor_changed_signal () {
            view.cursor_changed.connect (on_cursor_changed);
        }
        private void disconnect_view_cursor_changed_signal () {
            view.cursor_changed.disconnect (on_cursor_changed);
        }
    }
}

