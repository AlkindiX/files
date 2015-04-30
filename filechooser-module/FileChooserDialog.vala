// -*- Mode: vala; indent-tabs-mode: nil; tab-width: 4 -*-
/*-
 * Copyright (c) 2015 Pantheon Developers (http://launchpad.net/elementary)
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public
 * License along with this library; if not, write to the
 * Free Software Foundation, Inc., 59 Temple Place - Suite 330,
 * Boston, MA 02111-1307, USA.
 *
 * Authored by: Adam Bieńkowski <donadigos159@gmail.com>
 */

public class CustomFileChooserDialog : Object {
    private static Gtk.FileChooserDialog d;
    private static Gtk.FileChooser chooser;
    private static Gtk.Widget rootwidget;
    
    private static Gtk.Box container_box;
    private static Gtk.Button? gtk_folder_button = null;

    /* Response to get parent of the bottom box */
    private const int BUTTON_RESPONSE = -3;    

    /* Paths to widgets */
    private const string[] GTK_PATHBAR_PATH = { "widget", "browse_widgets_box", "browse_files_box", "browse_header_box" };
    private const string[] GTK_FILTERCHOSSER_PATH = { "extra_and_filters", "filter_combo_hbox" };
    private const string[] GTK_CREATEFOLDER_BUTTON = { "browse_header_stack", "browse_path_bar_hbox", "browse_new_folder_button" };

    private const string FILE_PREFIX = "file://";

    private GenericArray<string> path_list = new GenericArray<string> ();

    public CustomFileChooserDialog (Gtk.FileChooserDialog _dialog) {
        /* The "d" variable is the main dialog */
        d = _dialog;
        
        /* Main FileChooser interface */
        chooser = (d as Gtk.FileChooser);

        d.deletable = false;
        prepare_action_section ();
        setup_filter_box ();

        remove_gtk_widgets ();

        var header_bar = new Gtk.HeaderBar ();
        var button_back = new Gtk.Button.from_icon_name ("go-previous-symbolic", Gtk.IconSize.LARGE_TOOLBAR);
        var button_forward = new Gtk.Button.from_icon_name ("go-next-symbolic", Gtk.IconSize.LARGE_TOOLBAR);

        var pathbar = new Marlin.View.Chrome.LocationBar ();
        pathbar.path = FILE_PREFIX + chooser.get_current_folder ();
        pathbar.hexpand = true;

        header_bar.pack_start (button_back);
        header_bar.pack_start (button_forward);
        header_bar.pack_start (pathbar);
        if (gtk_folder_button != null
            && chooser.get_action () == Gtk.FileChooserAction.SELECT_FOLDER
            && chooser.get_action () == Gtk.FileChooserAction.CREATE_FOLDER) {
        	var create_folder_button = new Gtk.Button.from_icon_name ("folder-new", Gtk.IconSize.LARGE_TOOLBAR);
        	create_folder_button.clicked.connect (() => {
        		gtk_folder_button.clicked ();
        	});

        	header_bar.pack_end (create_folder_button);
        }


        d.set_titlebar (header_bar);
        d.show_all ();
        
        button_back.clicked.connect (() => {
            path_list.add (chooser.get_current_folder ());
            var parent = chooser.get_current_folder_file ().get_parent ();
            pathbar.path = FILE_PREFIX + parent.get_path ();
            
            try {
                chooser.set_current_folder_file (parent);
            } catch (Error e) {
                error (e.message);
            }
        });

        button_forward.clicked.connect (() => {
            if (path_list.length > 0) {
                int length = path_list.length - 1;
                pathbar.path = path_list.@get (length);
                chooser.set_current_folder (path_list.@get (length));
                path_list.remove (path_list.@get (length));
            }
        });

        chooser.current_folder_changed.connect (() => {
            button_forward.sensitive = (path_list.length > 0);
            pathbar.path = FILE_PREFIX + chooser.get_current_folder ();
            if (chooser.get_current_folder () == "/")
                button_back.sensitive = false;
            else
                button_back.sensitive = true;    
        });
        
        pathbar.change_to_file.connect ((file) => {
            chooser.set_current_folder (file);
        });
    }
    
    /* Remove GTK's native path bar and filefilter chooser by widgets names */
    private static void remove_gtk_widgets () {
        foreach (var root in d.get_children ()) {
            foreach (var w0 in (root as Gtk.Container).get_children ()) {
                if (w0.get_name () == GTK_PATHBAR_PATH[0]) {
                    /* Add top separator between headerbar and filechooser when is not SAVE action */
                    if (chooser.get_action () != Gtk.FileChooserAction.SAVE) {
                        var chooserwidget = w0.@ref () as Gtk.Container;
                        chooserwidget.vexpand = true;

                        (root as Gtk.Container).remove (w0);
                        var root_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
                        root_box.add (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
                        root_box.add (chooserwidget); 
                        (root as Gtk.Container).add (root_box);
                        rootwidget = chooserwidget;
                    } else {
                        rootwidget = w0;
                    }   

                    foreach (var w1 in (rootwidget as Gtk.Container).get_children ()) {
                        if (w1.get_name () == GTK_PATHBAR_PATH[1]) {
                            foreach (var paned in (w1 as Gtk.Container).get_children ()) {
                                foreach (var w2 in (paned as Gtk.Container).get_children ()) {
                                    if (w2.get_name () == GTK_PATHBAR_PATH[2]) {
                                        foreach (var w3 in (w2 as Gtk.Container).get_children ()) {
                                            if (w3.get_name () == GTK_PATHBAR_PATH[3]) {
                                            	foreach (var w4 in (w3 as Gtk.Container).get_children ()) {
                                            		if (w4.get_name () == GTK_CREATEFOLDER_BUTTON[0]) {
                                            			foreach (var w5 in (w4 as Gtk.Container).get_children ()) {
                                            				if (w5.get_name () == GTK_CREATEFOLDER_BUTTON[1]) {
                                            					foreach (var w6 in (w5 as Gtk.Container).get_children ()) {
                                            						if (w6.get_name () == GTK_CREATEFOLDER_BUTTON[2])
                                            							/* Register the button so we can use it's signal */
                                            							gtk_folder_button = w6.@ref () as Gtk.Button;
                                            					}	
                                            				}
                                            			}
                                            		}
                                            	}

                                                (w2 as Gtk.Container).remove (w3);
                                            }
                                        }
                                    }    
                                }
                            } 
                        } else {
                            if (w1.get_name () == GTK_FILTERCHOSSER_PATH[0]) {
                                foreach (var w5 in (w1 as Gtk.Container).get_children ()) {
                                    if (w5.get_name () == GTK_FILTERCHOSSER_PATH[1])
                                       (w1 as Gtk.Container).remove (w5);
                                }
                            }                            
                        }   
                    }
                }
            }  
        }   
    }

    private static void prepare_action_section () {
        var tmp = d.get_widget_for_response (BUTTON_RESPONSE);

        var container = tmp.get_parent ();
        container_box = container.get_parent () as Gtk.Box;             
    }
    
    private static void setup_filter_box () {
        var filters = chooser.list_filters (); 
        if (filters.length () > 0) {
            var combo_box = new Gtk.ComboBoxText ();
            combo_box.margin_top = 4;

            combo_box.changed.connect (() => {
                chooser.list_filters ().@foreach ((filter) => {
                    if (filter.get_filter_name () == combo_box.get_active_text ())
                        chooser.set_filter (filter);
                });
            });

            filters.foreach ((filter) => {
                var f = filter.@ref () as Gtk.FileFilter;
                combo_box.append_text (f.get_filter_name ()); 
            });

            combo_box.active = 0;
       
            var grid = new Gtk.Grid ();
            grid.margin_start = 5;
        	grid.add (combo_box);
		    container_box.add (grid);   
		}           
    }
}
