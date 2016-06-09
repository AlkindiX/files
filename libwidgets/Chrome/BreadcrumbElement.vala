/***
    Copyright (c) 2011 Lucas Baudin <xapantu@gmail.com>

    Marlin is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License as
    published by the Free Software Foundation; either version 2 of the
    License, or (at your option) any later version.

    Marlin is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
    General Public License for more details.

    You should have received a copy of the GNU General Public
    License along with this program; see the file COPYING.  If not,
    write to the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
    Boston, MA 02111-1307, USA.
*
***/

public class Marlin.View.Chrome.BreadcrumbElement : Object {

    private const int ICON_MARGIN = 3;
    private string icon_name; /*For testing */
    private Gdk.Pixbuf? icon = null;
    private int icon_width;

    public string? text {get; private set;}
    private double text_width;
    private double text_height;

    public double offset = 0;
    public double last_height = 0;
    public double x  = 0;

    public double natural_width {
        get {
            return text_width + icon_width + 2 * ICON_MARGIN + padding.left + padding.right;
        }
    }
    public double display_width = -1;
    public double real_width {
        get {
            return display_width > 0 ? display_width : natural_width;
        }
    }

    public bool hidden = false;
    public bool display = true;
    public bool can_shrink = true;
    public bool pressed = false;

    public bool text_is_displayed = true;
    private string _text_for_display = "";
    public string? text_for_display {
        set {
            _text_for_display = value;
            update_text_width ();
        }

        get {
            return _text_for_display;
        }
    }

    private Gtk.Border padding = Gtk.Border ();
    private Pango.Layout layout;
    private Gtk.Widget widget;

    public BreadcrumbElement (string text_, Gtk.Widget widget_, Gtk.StyleContext button_context) {
        text = text_;
        widget = widget_;
        padding = button_context.get_padding (button_context.get_state ());
        text_for_display = Uri.unescape_string (text);
    }

    public void set_icon (Gdk.Pixbuf icon_) {
        icon = icon_;
        icon_width = icon.get_width ();
    }
    public void set_icon_name (string icon_name_) {
        icon_name = icon_name_;
    }

    public double draw (Cairo.Context cr, double x, double y, double height, Gtk.StyleContext button_context, bool is_RTL, Gtk.Widget widget) {
        var state = button_context.get_state ();
        if (pressed)
            state |= Gtk.StateFlags.ACTIVE;

        padding = button_context.get_padding (state);
        double line_width = cr.get_line_width ();

        cr.restore ();
        cr.save ();
        last_height = height;
        cr.set_source_rgb (0,0,0);

        var width = this.real_width;
        var iw = icon_width + 2 * ICON_MARGIN;
        var room_for_text = text_is_displayed;
        var room_for_icon = true;

        var layout_width = (width - padding.left - padding.right);
        if (layout_width < iw) {
            room_for_icon = false;
            iw = 0;
            if (layout_width >= 0) {
                layout.set_width (Pango.units_from_double (layout_width));
            } else {
                room_for_text = false;
            }
        } else {
            layout_width -= iw;
            if (layout_width >= 0) {
                layout.set_width (Pango.units_from_double (layout_width));
            } else {
                room_for_text = false;
            }
        }
        /* Erase area for drawing */
        if (offset > 0.0) {
            if (is_RTL) {
                cr.move_to (x + height/2, y);
                cr.line_to (x, y + height/2);
                cr.line_to (x + height/2, y + height);
                cr.line_to (x - width, y + height);
                cr.line_to (x - width - height/2, y + height/2);
                cr.line_to (x - width, y);
                cr.close_path ();
                cr.clip ();
            } else {
                cr.move_to (x - height/2, y);
                cr.line_to (x, y + height/2);
                cr.line_to (x - height/2, y + height);
                cr.line_to (x + width, y + height);
                cr.line_to (x + width + height/2, y + height/2);
                cr.line_to (x + width, y);
                cr.close_path ();
                cr.clip ();
            }
        }

        if (pressed) { /* Highlight the breadcrumb */
            cr.save ();
            double base_x, left_x, right_x, arrow_right_x;
            base_x = x;
            if (is_RTL) {
                left_x = base_x + height / 2 - line_width;
                right_x = base_x - width;
                arrow_right_x = right_x - height / 2;
            } else {
                left_x = base_x - height / 2;
                right_x = base_x + width + line_width;
                arrow_right_x = right_x + height / 2;
            }
            var top_y = y + padding.top - line_width;
            var bottom_y = y + height - padding.bottom + line_width;
            var arrow_y = y + height / 2;
            cr.move_to (left_x, top_y);
            cr.line_to (base_x, arrow_y);
            cr.line_to (left_x, bottom_y);
            cr.line_to (right_x, bottom_y);
            cr.line_to (arrow_right_x, arrow_y);
            cr.line_to (right_x, top_y);
            cr.close_path ();

            cr.clip ();
            button_context.save ();
            button_context.set_state (Gtk.StateFlags.ACTIVE);
            button_context.render_background (cr, left_x, y, width + height + 2 * line_width, height);
            button_context.render_frame (cr, 0, padding.top - line_width, widget.get_allocated_width (), height - line_width);
            button_context.restore ();
            cr.restore ();
        }

        /* Draw the text and icon (if present and there is room) */
        Gdk.Pixbuf? icon_to_draw = icon;
        if (icon != null && (state & Gtk.StateFlags.BACKDROP) > 0) {
            icon_to_draw = Eel.gdk_pixbuf_lucent (icon_to_draw, 50);
        }

        if (is_RTL) {
            x -= padding.left;
            x += Math.sin (offset*Math.PI_2) * width;
            if (icon_to_draw == null) {
                if (room_for_text) {
                    button_context.render_layout (cr, x - width,
                                                  y + height/2 - text_height/2, layout);
                }
            } else if (!text_is_displayed) {
                if (room_for_icon) {
                    button_context.render_icon (cr, icon_to_draw, x - ICON_MARGIN - icon_width,
                                                y + height/2 - icon.get_height ()/2);
                }
            } else {
                if (room_for_icon) {
                    button_context.render_icon (cr, icon_to_draw, x - ICON_MARGIN - icon_width,
                                                y + height/2 - icon.get_height ()/2);
                }
                if (room_for_text) {
                    /* text_width already includes icon_width */
                    button_context.render_layout (cr, x - width,
                                                  y + height/2 - text_height/2, layout);
                }
            }
        } else {
            x += padding.left;
            x -= Math.sin (offset*Math.PI_2) * width;
            if (icon_to_draw == null) {
                if (room_for_text) {
                    button_context.render_layout (cr, x,
                                                  y + height/2 - text_height/2, layout);
                }
            } else if (!text_is_displayed) {
                if (room_for_icon) {
                    button_context.render_icon (cr, icon_to_draw, x + ICON_MARGIN,
                                                 y + height/2 - icon.get_height ()/2);
                }
            } else {
                if (room_for_icon) {
                    button_context.render_icon (cr, icon_to_draw, x + ICON_MARGIN,
                                                 y + height/2 - icon.get_height ()/2);
                }
                if (room_for_text) {
                    button_context.render_layout (cr, x + iw,
                                                  y + height/2 - text_height/2, layout);
                }
            }
        }

        /* Move to end of breadcrumb */
        if (is_RTL) {
            x -= (width);
        } else {
            x += width;
        }

        /* Draw the arrow-shaped separator */
        if (is_RTL) {
            cr.save ();
            cr.translate (x + height/4, y + height / 2);
            cr.rectangle (0, -height / 2 + line_width, -height, height - 2 * line_width);
            cr.clip ();
            cr.rotate (Math.PI_4);
            button_context.save ();
            button_context.add_class ("noradius-button");
            if (pressed)
                button_context.set_state (Gtk.StateFlags.ACTIVE);

            button_context.render_frame (cr, -height / 2, -height / 2, height, height);
            button_context.restore ();
            cr.restore ();
        } else {
            cr.save ();
            cr.translate (x - height / 4, y + height / 2);
            cr.rectangle (0, -height / 2 + line_width, height, height - 2 * line_width);
            cr.clip ();
            cr.rotate (Math.PI_4);
            button_context.save ();
            button_context.add_class ("noradius-button");
            if (pressed) {
                button_context.set_state (Gtk.StateFlags.ACTIVE);
            }
            button_context.render_frame (cr, -height / 2, -height / 2, height, height);
            button_context.restore ();
            cr.restore ();
        }

        /* Move to end of separator */
        if (is_RTL) {
            x -= height / 2;
        } else {
            x += height / 2;
        }

        return x;
    }

    private void update_text_width () {
        layout = widget.create_pango_layout (_text_for_display);
        layout.set_ellipsize (Pango.EllipsizeMode.MIDDLE);

        int width, height;
        layout.get_size (out width, out height);
        this.text_width = Pango.units_to_double (width);
        this.text_height = Pango.units_to_double (height);
    }

    /** To help testing **/
    public string get_icon_name () {
        if (icon_name != null) {
            return icon_name;
        } else {
            return "null";
        }
    }
}
