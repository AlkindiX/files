/*
 * Copyright (C) 2011 Lucas Baudin <xapantu@gmail.com>
 *
 * Author: Zeeshan Ali (Khattak) <zeeshanak@gnome.org> (from Rygel)
 *
 * This file is part of Marlin.
 *
 * Marlin is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 * 
 * Marlin is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License along
 * with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

public class Marlin.PluginManager : GLib.Object
{
    delegate Plugins.Base ModuleInitFunc ();
    Gee.HashMap<string,Plugins.Base> plugin_hash;
    Settings settings;
    string settings_field;
    string plugin_dir;
    List<string> names = null;
    bool in_available = false;
    public PluginManager(Settings settings, string field, string plugin_dir)
    {
        settings_field = field;
        this.settings = settings;
        this.plugin_dir = plugin_dir;
        plugin_hash = new Gee.HashMap<string,Plugins.Base>();
    }
    
    public void load_plugins()
    {
        load_modules_from_dir(plugin_dir + "/core/", true);
        load_modules_from_dir(plugin_dir);
    } 
    
    private void load_modules_from_dir (string path, bool force = false)
    {
        File dir = File.new_for_path(path);

        string attributes = FILE_ATTRIBUTE_STANDARD_NAME + "," +
                            FILE_ATTRIBUTE_STANDARD_TYPE + "," +
                            FILE_ATTRIBUTE_STANDARD_CONTENT_TYPE;

        FileInfo info;
        FileEnumerator enumerator;

        try
        {
            enumerator = dir.enumerate_children
                                        (attributes,
                                         FileQueryInfoFlags.NONE);

            info = enumerator.next_file ();
        }
        catch(Error error)
        {
            critical ("Error listing contents of folder '%s': %s",
                      dir.get_path (),
                      error.message);

            return;
        }

        while(info != null)
        {
            string file_name = info.get_name ();
            string file_path = Path.build_filename (dir.get_path (), file_name);

            File file = File.new_for_path (file_path);

            if(file_name.has_suffix(".plug"))
            {
                load_plugin_keyfile(file_path, dir.get_path (), force);
            }
            info = enumerator.next_file ();
        }
    }

    void load_module(string file_path)
    {
        Module module = Module.open (file_path, ModuleFlags.BIND_LOCAL);
        if (module == null)
        {
            warning ("Failed to load module from path '%s': %s",
                     file_path,
                     Module.error ());
            return;
        }

        void* function;

        if (!module.symbol("module_init", out function)) {
            warning ("Failed to find entry point function '%s' in '%s': %s",
                     "module_init",
                     file_path,
                     Module.error ());
            return;
        }

        ModuleInitFunc module_init = (ModuleInitFunc) function;
        assert (module_init != null);

        /* We don't want our modules to ever unload */
        module.make_resident ();
        Plugins.Base plug = module_init();

        debug ("Loaded module source: '%s'", module.name());
        
        if(plug != null)
            plugin_hash.set (file_path, plug);
    }
    
    void load_plugin_keyfile(string path, string parent, bool force)
    {
        var keyfile = new KeyFile();
        try
        {
            keyfile.load_from_file(path, KeyFileFlags.NONE);
            string name = keyfile.get_string("Plugin", "Name");
            if(in_available)
            {
                names.append(name);
            }
            else if(force || name in settings.get_strv(settings_field))
            {
                load_module(Path.build_filename(parent, keyfile.get_string("Plugin", "File")));
            }
        }
        catch(Error e)
        {
            warning("Couldn't open thie keyfile: %s, %s", path, e.message);
        }
    }
    
    public void hook_context_menu(Gtk.Widget win)
    {
        foreach(var plugin in plugin_hash.values) plugin.context_menu(win);
    }
    
    public void ui(Gtk.UIManager data)
    {
        foreach(var plugin in plugin_hash.values) plugin.ui(data);
    }
    
    public void directory_loaded(void* path)
    {
        foreach(var plugin in plugin_hash.values) plugin.directory_loaded(path);
    }
    
    public void interface_loaded(Gtk.Widget win)
    {
        foreach(var plugin in plugin_hash.values) plugin.interface_loaded(win);
    }
    
    public void update_sidebar(Gtk.Widget win)
    {
        foreach(var plugin in plugin_hash.values) plugin.update_sidebar(win);
    }
    
    public void file(List<Object> files)
    {
        foreach(var plugin in plugin_hash.values) plugin.file(files);
    }
    
    public void add_plugin(string path)
    {
    }
    
    public void load_plugin(string path)
    {
    }
    
    public List<string> get_available_plugins()
    {
        names = new List<string>();
        in_available = true;
        load_modules_from_dir(plugin_dir, false);
        in_available = false;
        return names.copy();
    }
    
    public bool disable_plugin(string path)
    {
        string[] plugs = settings.get_strv(settings_field);
        string[] plugs_ = new string[plugs.length - 1];
        bool found = false;
        int i = 0;
        foreach(var name in plugs)
        {
            if(name != path)
            {
                plugs[i] = name;
            }
            else found = true;
            i++;
        }
        if(found) settings.set_strv(settings_field, plugs_);
        return found;
    }
}
