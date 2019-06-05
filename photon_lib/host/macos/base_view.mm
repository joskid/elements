/*=============================================================================
   Copyright (c) 2016-2019 Joel de Guzman

   Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/
#include <photon/base_view.hpp>
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include <memory>
#include <map>
#include <cairo-quartz.h>

#if ! __has_feature(objc_arc)
# error "ARC is off"
#endif

namespace ph = cycfi::photon;
using key_map = std::map<ph::key_code, ph::key_action>;

///////////////////////////////////////////////////////////////////////////////
// Helper utils

namespace
{
   CFBundleRef GetBundleFromExecutable(const char* filepath)
   {
      NSString* execStr = [NSString stringWithCString:filepath encoding:NSUTF8StringEncoding];
      NSString* macOSStr = [execStr stringByDeletingLastPathComponent];
      NSString* contentsStr = [macOSStr stringByDeletingLastPathComponent];
      NSString* bundleStr = [contentsStr stringByDeletingLastPathComponent];
      return CFBundleCreate (0, (CFURLRef)[NSURL fileURLWithPath:bundleStr isDirectory:YES]);
   }

   CFBundleRef GetCurrentBundle()
   {
      Dl_info info;
      if (dladdr ((const void*)GetCurrentBundle, &info))
      {
         if (info.dli_fname)
         {
            return GetBundleFromExecutable(info.dli_fname);
         }
      }
      return 0;
   }

   struct resource_setter
   {
      resource_setter()
      {
         // Before anything else, set the working directory so we can access
         // our resources
         CFBundleRef mainBundle = GetCurrentBundle();
         CFURLRef resourcesURL = CFBundleCopyResourcesDirectoryURL(mainBundle);
         char path[PATH_MAX];
         CFURLGetFileSystemRepresentation(resourcesURL, TRUE, (UInt8 *)path, PATH_MAX);
         CFRelease(resourcesURL);
         chdir(path);
      }
   };
}

namespace cycfi { namespace photon
{
   // These functions are defined in key.mm:
   key_code    translate_key(unsigned int key);
   int         translate_flags(NSUInteger flags);
   NSUInteger  translate_key_to_modifier_flag(key_code key);
}}

namespace
{
   // Defines a constant for empty ranges in NSTextInputClient
   NSRange const kEmptyRange = { NSNotFound, 0 };

   float transformY(float y)
   {
      return CGDisplayBounds(CGMainDisplayID()).size.height - y;
   }

   ph::mouse_button get_button(NSEvent* event, NSView* self, bool down = true)
   {
      auto pos = [event locationInWindow];
      auto click_count = [event clickCount];
      auto const mods = ph::translate_flags([event modifierFlags]);
      pos = [self convertPoint:pos fromView:nil];

      return {
         down,
         int(click_count),
         ph::mouse_button::left,
         mods,
         { float(pos.x), float(pos.y) }
      };
   }

   void handle_key(key_map& keys, ph::base_view& _view, ph::key_info k)
   {
      using ph::key_action;
      bool repeated = false;

      if (k.action == key_action::release && keys[k.key] == key_action::release)
         return;

      if (k.action == key_action::press && keys[k.key] == key_action::press)
         repeated = true;

      keys[k.key] = k.action;

      if (repeated)
         k.action = key_action::repeat;

      _view.key(k);
   }

   void get_window_pos(NSWindow* window, int& xpos, int& ypos)
   {
      NSRect const content_rect =
         [window contentRectForFrameRect:[window frame]];

      if (xpos)
         xpos = content_rect.origin.x;
      if (ypos)
         ypos = transformY(content_rect.origin.y + content_rect.size.height);
   }

   void handle_text(ph::base_view& _view, ph::text_info info)
   {
      if (info.codepoint < 32 || (info.codepoint > 126 && info.codepoint < 160))
         return;
      _view.text(info);
   }
}

///////////////////////////////////////////////////////////////////////////////
// PhotonView Interface

@interface PhotonView : NSView <NSTextInputClient>
{
   NSTimer*                         _idle_task;
   NSTrackingArea*                  _tracking_area;
   NSMutableAttributedString*       _marked_text;
   key_map                          _keys;
   bool                             _start;
   ph::base_view*                   _view;
}
@end

@implementation PhotonView

- (void) photon_init : (ph::base_view*) view_
{
   static resource_setter set_resource_pwd;

   _view = view_;
   _start = true;
   _idle_task =
      [NSTimer scheduledTimerWithTimeInterval : 0.016 // 60Hz
           target : self
         selector : @selector(on_tick:)
         userInfo : nil
          repeats : YES
      ];

   _tracking_area = nil;
   [self updateTrackingAreas];

   _marked_text = [[NSMutableAttributedString alloc] init];
}

- (void) dealloc
{
   _view = nullptr;
}

- (void) on_tick : (id) sender
{
   _view->tick();
}

- (void) attach_notifications
{
   [[NSNotificationCenter defaultCenter]
      addObserver : self
         selector : @selector(windowDidBecomeKey:)
             name : NSWindowDidBecomeKeyNotification
           object : [self window]
   ];

   [[NSNotificationCenter defaultCenter]
      addObserver : self
         selector : @selector(windowDidResignKey:)
             name : NSWindowDidResignMainNotification
           object : [self window]
   ];
}

- (void) detach_notifications
{
   [[NSNotificationCenter defaultCenter]
      removeObserver : self
                name : NSWindowDidBecomeKeyNotification
              object : [self window]
   ];

   [[NSNotificationCenter defaultCenter]
      removeObserver : self
                name : NSWindowDidResignMainNotification
              object : [self window]
   ];
}

- (BOOL) canBecomeKeyView
{
   return YES;
}

- (BOOL) acceptsFirstResponder
{
   return YES;
}

-(BOOL) isFlipped
{
   return YES;
}

- (BOOL) canBecomeKeyWindow
{
    return YES;
}

- (BOOL) canBecomeMainWindow
{
    return YES;
}

- (void) drawRect : (NSRect)dirty
{
   [super drawRect : dirty];

   auto w = [self bounds].size.width;
   auto h = [self bounds].size.height;

   auto context_ref = NSGraphicsContext.currentContext.CGContext;
   cairo_surface_t* surface = cairo_quartz_surface_create_for_cg_context(context_ref, w, h);
   cairo_t* context = cairo_create(surface);

   _view->draw(context,
      {
         float(dirty.origin.x),
         float(dirty.origin.y),
         float(dirty.origin.x + dirty.size.width),
         float(dirty.origin.y + dirty.size.height)
      }
   );

   cairo_surface_destroy(surface);
   cairo_destroy(context);
}

- (void) mouseDown : (NSEvent*) event
{
   _view->click(get_button(event, self));
   [self displayIfNeeded];
}

- (void) mouseDragged : (NSEvent*) event
{
   _view->drag(get_button(event, self));
   [self displayIfNeeded];
}

- (void) mouseUp : (NSEvent*) event
{
   _view->click(get_button(event, self, false));
   [self displayIfNeeded];
}

- (void) updateTrackingAreas
{
   if (_tracking_area != nil)
      [self removeTrackingArea : _tracking_area];

   NSTrackingAreaOptions const options =
         NSTrackingMouseEnteredAndExited |
         NSTrackingActiveAlways |
         NSTrackingMouseMoved
      ;

   _tracking_area =
      [[NSTrackingArea alloc]
         initWithRect : [self bounds]
              options : options
                owner : self
             userInfo : nil
      ];

    [self addTrackingArea : _tracking_area];
    [super updateTrackingAreas];
}

- (void) mouseEntered : (NSEvent*) event
{
   [[self window] setAcceptsMouseMovedEvents : YES];
   [[self window] makeFirstResponder : self];
   auto pos = [event locationInWindow];
   pos = [self convertPoint : pos fromView : nil];
   _view->cursor({ float(pos.x), float(pos.y) }, ph::cursor_tracking::entering);
   [self displayIfNeeded];
}

- (void) mouseExited : (NSEvent*) event
{
   [[self window] setAcceptsMouseMovedEvents : NO];
   auto pos = [event locationInWindow];
   pos = [self convertPoint : pos fromView : nil];
   _view->cursor({ float(pos.x), float(pos.y) }, ph::cursor_tracking::leaving);
   [self displayIfNeeded];
}

- (void) mouseMoved : (NSEvent*) event
{
   auto pos = [event locationInWindow];
   pos = [self convertPoint : pos fromView : nil];
   _view->cursor({ float(pos.x), float(pos.y) }, ph::cursor_tracking::hovering);
   [self displayIfNeeded];
   [super mouseMoved: event];
}

- (void) scrollWheel : (NSEvent*) event
{
   float delta_x = [event scrollingDeltaX];
   float delta_y = [event scrollingDeltaY];

   if (event.directionInvertedFromDevice)
      delta_y = -delta_y;

   auto pos = [event locationInWindow];
   pos = [self convertPoint:pos fromView:nil];
   if (fabs(delta_x) > 0.0 || fabs(delta_y) > 0.0)
      _view->scroll({ delta_x, delta_y }, { float(pos.x), float(pos.y) });
   [self displayIfNeeded];
}

- (void) keyDown : (NSEvent*) event
{
   auto const key = ph::translate_key([event keyCode]);
   auto const mods = ph::translate_flags([event modifierFlags]);
   handle_key(_keys, *_view, { key, ph::key_action::press, mods });
   [self interpretKeyEvents : [NSArray arrayWithObject:event]];
}

- (void) flagsChanged : (NSEvent*) event
{
   auto const modifier_flags =
      [event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask;
   auto const key = ph::translate_key([event keyCode]);
   auto const mods = ph::translate_flags(modifier_flags);
   auto const key_flag = ph::translate_key_to_modifier_flag(key);

   ph::key_action action;
   if (key_flag & modifier_flags)
   {
     if (_keys[key] == ph::key_action::press)
        action = ph::key_action::release;
     else
        action = ph::key_action::press;
   }
   else
   {
     action = ph::key_action::release;
   }

   handle_key(_keys, *_view, { key, action, mods });
}

- (void) keyUp : (NSEvent*) event
{
   auto const key = ph::translate_key([event keyCode]);
   auto const mods = ph::translate_flags([event modifierFlags]);

   handle_key(_keys, *_view, { key, ph::key_action::release, mods });
}

- (BOOL) hasMarkedText
{
   return [_marked_text length] > 0;
}

- (NSRange) markedRange
{
   if ([_marked_text length] > 0)
      return NSMakeRange(0, [_marked_text length] - 1);
   else
      return kEmptyRange;
}

- (NSRange) selectedRange
{
    return kEmptyRange;
}

- (void)setMarkedText : (id)string
        selectedRange : (NSRange)selectedRange
     replacementRange : (NSRange)replacementRange
{
   if ([string isKindOfClass:[NSAttributedString class]])
      (void)[_marked_text initWithAttributedString:string];
   else
      (void)[_marked_text initWithString:string];
}

- (void) unmarkText
{
   [[_marked_text mutableString] setString:@""];
}

- (NSArray*) validAttributesForMarkedText
{
   return [NSArray array];
}

- (NSAttributedString*) attributedSubstringForProposedRange : (NSRange)range
                                                actualRange : (NSRangePointer)actualRange
{
   return nil;
}

- (NSUInteger) characterIndexForPoint : (NSPoint)point
{
   return 0;
}

- (NSRect) firstRectForCharacterRange : (NSRange)range
                          actualRange : (NSRangePointer)actualRange
{
   int xpos, ypos;
   get_window_pos([self window], xpos, ypos);
   NSRect const content_rect = [[self window] frame];
   return NSMakeRect(xpos, transformY(ypos + content_rect.size.height), 0.0, 0.0);
}

- (void) insertText:(id)string replacementRange : (NSRange)replacementRange
{
   auto*       event = [NSApp currentEvent];
   auto const  mods = ph::translate_flags([event modifierFlags]);
   auto*       characters = ([string isKindOfClass:[NSAttributedString class]]) ?
                 [string string] : (NSString*) string;

   NSUInteger i, length = [characters length];
   for (i = 0;  i < length;  i++)
   {
     const unichar codepoint = [characters characterAtIndex:i];
     if ((codepoint & 0xff00) == 0xf700)
        continue;
     handle_text(*_view, { codepoint, mods });
   }
}

- (void) doCommandBySelector : (SEL) selector
{
}

-(void) windowDidBecomeKey : (NSNotification*) notification
{
   _view->focus(ph::focus_request::begin_focus);
}

-(void) windowDidResignKey : (NSNotification*) notification
{
   _view->focus(ph::focus_request::end_focus);
}

@end // @implementation PhotonView

namespace cycfi { namespace photon
{
   namespace
   {
      PhotonView* get_mac_view(ph::host_view h)
      {
         return (__bridge PhotonView*) h;
      }
   }

   base_view::base_view(host_window h)
   {
      NSView* parent_view = (__bridge NSView*) h;
      if ([parent_view isKindOfClass:[NSView class]])
      {
         auto parent_frame = [parent_view frame];
         auto frame = NSMakeRect(0, 0, parent_frame.size.width, parent_frame.size.height);
         PhotonView* content = [[PhotonView alloc] initWithFrame:frame];

         _view = (__bridge void*) content;
         [content photon_init : this];
         [parent_view addSubview : content];
      }
      else
      {
         PhotonView* content = [[PhotonView alloc] init];
         _view = (__bridge void*) content;
         content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
         [content photon_init : this];

         NSWindow* window_ = (__bridge NSWindow*) h;
         bool b = [window_ isKindOfClass:[NSWindow class]];
         [window_ setContentView : content];
      }

      [get_mac_view(host()) attach_notifications];
   }

   base_view::~base_view()
   {
      auto ns_view = get_mac_view(host());
      [ns_view detach_notifications];
      [ns_view removeFromSuperview];
      _view = nil;
   }

   point base_view::cursor_pos() const
   {
      auto  ns_view = get_mac_view(host());
      auto  frame_height = [ns_view frame].size.height;
      auto  pos = [[ns_view window] mouseLocationOutsideOfEventStream];
      return { float(pos.x), float(frame_height - pos.y - 1) };
   }

   point base_view::size() const
   {
      auto frame = [get_mac_view(host()) frame];
      return { float(frame.size.width), float(frame.size.height) };
   }

   void base_view::size(point p)
   {
      [get_mac_view(host()) setFrameSize : NSSize{ p.x, p.y }];
   }

   void base_view::refresh()
   {
      [get_mac_view(host()) setNeedsDisplay : YES];
   }

   void base_view::refresh(rect area)
   {
      [get_mac_view(host()) setNeedsDisplayInRect
         : CGRectMake(area.left, area.top, area.width(), area.height())
      ];
   }

   std::string clipboard()
   {
      NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
      if (![[pasteboard types] containsObject:NSPasteboardTypeString])
         return {};

      NSString* object = [pasteboard stringForType:NSPasteboardTypeString];
      if (!object)
         return {};
      return [object UTF8String];
   }

   void clipboard(std::string const& text)
   {
      NSArray* types = [NSArray arrayWithObjects:NSPasteboardTypeString, nil];

      NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
      [pasteboard declareTypes:types owner:nil];
      [pasteboard setString:[NSString stringWithUTF8String:text.c_str()]
                    forType:NSPasteboardTypeString];
   }

   void set_cursor(cursor_type type)
   {
      switch (type)
      {
         case cursor_type::arrow:
            [[NSCursor arrowCursor] set];
            break;
         case cursor_type::ibeam:
            [[NSCursor IBeamCursor] set];
            break;
         case cursor_type::cross_hair:
            [[NSCursor crosshairCursor] set];
            break;
         case cursor_type::hand:
            [[NSCursor openHandCursor] set];
            break;
         case cursor_type::h_resize:
            [[NSCursor resizeLeftRightCursor] set];
            break;
         case cursor_type::v_resize:
            [[NSCursor resizeUpDownCursor] set];
            break;
      }
   }
}}

