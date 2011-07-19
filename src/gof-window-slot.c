/*
 * Copyright (C) 2010 ammonkey
 *
 * This library is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License
 * version 3.0 as published by the Free Software Foundation.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License version 3.0 for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library. If not, see
 * <http://www.gnu.org/licenses/>.
 *
 * Author: ammonkey <am.monkeyd@gmail.com>
 */

#include "gof-window-slot.h"
#include "fm-icon-view.h"
#include "fm-list-view.h"
#include "fm-columns-view.h"
#include "marlin-view-window.h"

static void gof_window_slot_init       (GOFWindowSlot *slot);
static void gof_window_slot_class_init (GOFWindowSlotClass *class);
static void gof_window_slot_finalize   (GObject *object);

G_DEFINE_TYPE (GOFWindowSlot, gof_window_slot, G_TYPE_OBJECT)
#define parent_class gof_window_slot_parent_class

enum {
    ACTIVE,
    INACTIVE,
    LAST_SIGNAL
};

static guint signals[LAST_SIGNAL] = { 0 };


static void
gof_window_slot_init (GOFWindowSlot *slot)
{
}

static void
gof_window_slot_class_init (GOFWindowSlotClass *class)
{
    signals[ACTIVE] =
	g_signal_new ("active",
		      G_TYPE_FROM_CLASS (class),
		      G_SIGNAL_RUN_LAST,
		      G_STRUCT_OFFSET (GOFWindowSlotClass, active),
		      NULL, NULL,
		      g_cclosure_marshal_VOID__VOID,
		      G_TYPE_NONE, 0);

    signals[INACTIVE] =
	g_signal_new ("inactive",
		      G_TYPE_FROM_CLASS (class),
		      G_SIGNAL_RUN_LAST,
		      G_STRUCT_OFFSET (GOFWindowSlotClass, inactive),
		      NULL, NULL,
		      g_cclosure_marshal_VOID__VOID,
		      G_TYPE_NONE, 0);

    G_OBJECT_CLASS (class)->finalize = gof_window_slot_finalize;
}

static void
gof_window_slot_finalize (GObject *object)
{
    GOFWindowSlot *slot = GOF_WINDOW_SLOT (object);
    g_warning ("%s %s\n", G_STRFUNC, slot->directory->file->uri);

    //load_dir_async_cancel(slot->directory);
    g_object_unref(slot->directory);
    g_object_unref(slot->location);
    G_OBJECT_CLASS (parent_class)->finalize (object);
    printf ("test %s\n", G_STRFUNC);
    /* avoid a warning in vala code: slot is freed in ViewContainer */
    //slot = NULL;
}

void
gof_window_column_add (GOFWindowSlot *slot, GtkWidget *column)
{
    GtkWidget *hpane = gtk_hpaned_new();
    gtk_widget_show (hpane);
    gtk_container_add(GTK_CONTAINER(slot->colpane), hpane);
    GtkWidget *vbox2 = gtk_hbox_new(FALSE, 0);
    gtk_widget_show (vbox2);
    slot->colpane = vbox2;
    slot->hpane = hpane;

    gtk_widget_set_size_request (column, slot->mwcols->preferred_column_width, -1);

    gtk_paned_pack1 (GTK_PANED (hpane), column, FALSE, FALSE);
    gtk_paned_pack2 (GTK_PANED (hpane), vbox2, TRUE, FALSE);
}

void
gof_window_columns_add_location (GOFWindowSlot *slot, GFile *location)
{
    gint current_slot_position = 0;
    gint i;
    GList* mwcols_slot_tmp = slot->mwcols->slot;
    slot->mwcols->active_slot = slot;
    gtk_container_foreach (GTK_CONTAINER (slot->colpane), (GtkCallback)gtk_widget_destroy, NULL);
    
    current_slot_position = g_list_index(slot->mwcols->slot, slot);
    if(current_slot_position == -1)
    {
        g_warning("Can't find the slot you are viewing, this should *not* happen.");
    }
    else
    {
        slot->mwcols->slot = NULL;
        for(i = 0; i <= current_slot_position; i++)
        {
            slot->mwcols->slot = g_list_append(slot->mwcols->slot, g_list_nth_data(mwcols_slot_tmp, i));
        }
    }
    
    marlin_window_columns_add (slot->mwcols, location);
}

void
gof_window_columns_add_preview (GOFWindowSlot *slot, GtkWidget *context_view)
{
    slot->mwcols->active_slot = slot;
    gtk_container_foreach (GTK_CONTAINER (slot->colpane), (GtkCallback)gtk_widget_destroy, NULL);
    gtk_container_add(GTK_CONTAINER(slot->colpane), context_view);
}

GOFWindowSlot *
gof_window_slot_new (GFile *location, GObject *ctab)
{
    GOFWindowSlot *slot;
    slot = g_object_new (GOF_TYPE_WINDOW_SLOT, NULL);
    slot->location = g_object_ref (location);
    slot->ctab = ctab;

    slot->directory = gof_directory_async_new_from_gfile (slot->location);
    g_message ("%s %s\n", G_STRFUNC, slot->directory->file->uri);

    return slot;
}

/**
 * Used to make a view in the list view.
 * It replaces the content of the current tab by it own widget (wich is a list
 * of the current files of this directory).
 **/
void
gof_window_slot_make_icon_view (GOFWindowSlot *slot)
{
    slot->view_box = GTK_WIDGET (g_object_new (FM_TYPE_ICON_VIEW,
                                               "window-slot", slot, NULL));
    marlin_view_view_container_set_content (slot->ctab, slot->view_box);
    gof_directory_async_load (slot->directory);
}

void
gof_window_slot_make_list_view (GOFWindowSlot *slot)
{
    slot->view_box = GTK_WIDGET (g_object_new (FM_TYPE_LIST_VIEW,
                                               "window-slot", slot, NULL));
    marlin_view_view_container_set_content (slot->ctab, slot->view_box);
    gof_directory_async_load (slot->directory);
}

/**
 * Used to make a view in the column view.
 * It replaces the content of the current tab by it own widget (wich is a list
 * of the current files of this directory).
 *
 * Note:
 * In miller column view, you'll have multiple column displayed, not only this
 * one.
 **/
void
gof_window_slot_make_column_view (GOFWindowSlot *slot)
{
    slot->view_box = GTK_WIDGET (g_object_new (FM_TYPE_COLUMNS_VIEW,
                                               "window-slot", slot, NULL));
    gof_directory_async_load (slot->directory);
}

void
gof_window_slot_freeze_updates (GOFWindowSlot *slot)
{
    if (slot->mwcols != NULL)
        marlin_window_columns_freeze_updates (slot->mwcols);
}

void
gof_window_slot_unfreeze_updates (GOFWindowSlot *slot)
{
    if (slot->mwcols != NULL)
        marlin_window_columns_unfreeze_updates (slot->mwcols);
}

