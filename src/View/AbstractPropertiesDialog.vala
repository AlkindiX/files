/*
* Copyright (c) 2011 Marlin Developers (http://launchpad.net/marlin)
* Copyright (c) 2015-2016 elementary LLC (http://launchpad.net/pantheon-files)
*
* This program is free software; you can redistribute it and/or
* modify it under the terms of the GNU General Public
* License as published by the Free Software Foundation; either
* version 3 of the License, or (at your option) any later version.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
* General Public License for more details.
*
* You should have received a copy of the GNU General Public
* License along with this program; if not, write to the
* Free Software Foundation, Inc., 59 Temple Place - Suite 330,
* Boston, MA 02111-1307, USA.
*
* Authored by: ammonkey <am.monkeyd@gmail.com>
*/
namespace Marlin.View {

protected abstract class AbstractPropertiesDialog : Gtk.Dialog {
    protected Gtk.Grid info_grid;
    protected Gtk.Grid layout;
    protected Gtk.Stack stack;
    protected Gtk.StackSwitcher stack_switcher;
    protected Gtk.Widget header_title;
    protected Granite.Widgets.StorageBar? storagebar = null;

    protected enum PanelType {
        INFO,
        PERMISSIONS,
        PREVIEW
    }

    public AbstractPropertiesDialog (string _title, Gtk.Window parent) {
        title = _title;
        resizable = false;
        deletable = false;
        set_default_size (220, -1);
        transient_for = parent;
        window_position = Gtk.WindowPosition.CENTER_ON_PARENT;
        border_width = 6;
        destroy_with_parent = true;

        var info_header = new HeaderLabel (_("Info"));

        info_grid = new Gtk.Grid ();
        info_grid.column_spacing = 6;
        info_grid.row_spacing = 6;
        info_grid.attach (info_header, 0, 0, 2, 1);

        stack = new Gtk.Stack ();
        stack.margin_bottom = 12;
        stack.add_titled (info_grid, PanelType.INFO.to_string (), _("General"));

        stack_switcher = new Gtk.StackSwitcher ();
        stack_switcher.halign = Gtk.Align.CENTER;
        stack_switcher.margin_top = 12;
        stack_switcher.no_show_all = true;
        stack_switcher.stack = stack;

        layout = new Gtk.Grid ();
        layout.margin = 6;
        layout.margin_top = 0;
        layout.column_spacing = 12;
        layout.row_spacing = 6;
        layout.attach (stack_switcher, 0, 1, 2, 1);
        layout.attach (stack, 0, 2, 2, 1);

        var content_area = get_content_area () as Gtk.Box;
        content_area.add (layout);

        add_button (_("Close"), Gtk.ResponseType.CLOSE);
        response.connect ((source, type) => {
            switch (type) {
                case Gtk.ResponseType.CLOSE:
                    destroy ();
                    break;
            }
        });

        present ();
    }

    protected void create_header_title () {
        header_title.get_style_context ().add_class ("h2");
        header_title.hexpand = true;
        header_title.margin_top = 6;
        header_title.valign = Gtk.Align.CENTER;
        layout.attach (header_title, 1, 0, 1, 1);
    }

    protected void overlay_emblems (Gtk.Image file_icon, List<string>? emblems_list) {
        if (emblems_list != null) {
            int pos = 0;
            var emblem_grid = new Gtk.Grid ();
            emblem_grid.orientation = Gtk.Orientation.VERTICAL;
            emblem_grid.halign = Gtk.Align.END;
            emblem_grid.valign = Gtk.Align.END;

            foreach (string emblem_name in emblems_list) {
                var emblem = new Gtk.Image.from_icon_name (emblem_name, Gtk.IconSize.BUTTON);
                emblem_grid.add (emblem);

                pos++;
                if (pos > 3) { /* Only room for 3 emblems */
                    break;
                }
            }

            var file_img = new Gtk.Overlay ();
            file_img.set_size_request (48, 48);
            file_img.valign = Gtk.Align.CENTER;
            file_img.add_overlay (file_icon);
            file_img.add_overlay (emblem_grid);
            layout.attach (file_img, 0, 0, 1, 1);
        } else {
            layout.attach (file_icon, 0, 0, 1, 1);
        }

    }

    protected void add_section (Gtk.Stack stack, string title, string name, Gtk.Container content) {
        if (content != null) {
            stack.add_titled (content, name, title);
        }

        /* Only show the stack switcher when there's more than a single tab */
        if (stack.get_children ().length () > 1) {
            stack_switcher.show ();
        }
    }

    protected void create_storage_bar (GLib.FileInfo file_info, int line) {
        var storage_header = new HeaderLabel (_("Device Usage"));
        info_grid.attach (storage_header, 0, line, 1, 1);

        if (file_info != null &&
            file_info.has_attribute (FileAttribute.FILESYSTEM_SIZE) &&
            file_info.has_attribute (FileAttribute.FILESYSTEM_FREE)) {

            uint64 fs_capacity = file_info.get_attribute_uint64 (FileAttribute.FILESYSTEM_SIZE);
            uint64 fs_used = file_info.get_attribute_uint64 (FileAttribute.FILESYSTEM_USED);

            storagebar = new Granite.Widgets.StorageBar.with_total_usage (fs_capacity, fs_used);

            info_grid.attach (storagebar, 0, line + 1, 4, 1);
        } else {
            /* We're not able to gether the usage statistics, show an error
             * message to let the user know. */
            var capacity_label = new KeyLabel (_("Capacity:"));
            var capacity_value = new ValueLabel (_("Unknown"));

            var available_label = new KeyLabel (_("Available:"));
            var available_value = new ValueLabel (_("Unknown"));

            var used_label = new KeyLabel (_("Used:"));
            var used_value = new ValueLabel (_("Unknown"));

            info_grid.attach (capacity_label, 0, line + 1, 1, 1);
            info_grid.attach_next_to (capacity_value, capacity_label, Gtk.PositionType.RIGHT);
            info_grid.attach (available_label, 0, line + 2, 1, 1);
            info_grid.attach_next_to (available_value, available_label, Gtk.PositionType.RIGHT);
            info_grid.attach (used_label, 0, line + 3, 1, 1);
            info_grid.attach_next_to (used_value, used_label, Gtk.PositionType.RIGHT);
        }
    }

    protected void update_selection_usage (uint64 size) {
        if (storagebar != null) {
            storagebar.update_block_size (Granite.Widgets.StorageBar.ItemDescription.FILES, size);
        }
    }
}

protected class HeaderLabel : Gtk.Label {
    public HeaderLabel (string _label) {
        halign = Gtk.Align.START;
        get_style_context ().add_class ("h4");
        label = _label;
    }
}

protected class KeyLabel : Gtk.Label {
    public KeyLabel (string _label) {
        halign = Gtk.Align.END;
        label = _label;
        margin_start = 12;
    }
}

protected class ValueLabel : Gtk.Label {
    public ValueLabel (string _label) {
        can_focus = true;
        halign = Gtk.Align.START;
        label = _label;
        selectable = true;
        use_markup = true;
    }
}
}
