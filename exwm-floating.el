;;; exwm-floating.el --- Floating Module for EXWM  -*- lexical-binding: t -*-

;; Copyright (C) 2015 Chris Feng

;; Author: Chris Feng <chris.w.feng@gmail.com>
;; Keywords: unix

;; This file is not part of GNU Emacs.

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this file.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This module deals with the conversion between floating and non-floating
;; states and implements moving/resizing operations on floating windows.

;; Todo:
;; + move/resize with keyboard.

;;; Code:

(require 'xcb-cursor)

(defvar exwm-floating-border-width 1 "Border width of the floating window.")
(defvar exwm-floating-border-color "blue"
  "Border color of the floating window.")

(defun exwm-floating--set-floating (id)
  "Make window ID floating."
  (interactive)
  (setq exwm-input--focus-lock t)
  (when (get-buffer-window (exwm--id->buffer id)) ;window in non-floating state
    (set-window-buffer (selected-window) (other-buffer))) ;hide it first
  (let* ((original-frame
          (with-current-buffer (exwm--id->buffer id)
            (if (and exwm-transient-for (exwm--id->buffer exwm-transient-for))
                ;; Place a modal in the same workspace with its leading window
                (with-current-buffer (exwm--id->buffer exwm-transient-for)
                  exwm--frame)
              ;; Fallback to current workspace
              exwm-workspace--current)))
         (original-id (frame-parameter original-frame 'exwm-window-id))
         ;; Create new frame
         (frame (with-current-buffer "*scratch*"
                  (make-frame `((minibuffer . nil) ;use the one on workspace
                                (background-color
                                 . ,exwm-floating-border-color)
                                (internal-border-width
                                 . ,exwm-floating-border-width)
                                (unsplittable . t))))) ;and fix the size later
         (frame-id (string-to-int (frame-parameter frame 'window-id)))
         (outer-id (string-to-int (frame-parameter frame 'outer-window-id)))
         (window (frame-first-window frame)) ;and it's the only window
         (x (slot-value exwm--geometry 'x))
         (y (slot-value exwm--geometry 'y))
         (width (slot-value exwm--geometry 'width))
         (height (slot-value exwm--geometry 'height)))
    ;; Save window IDs
    (set-frame-parameter frame 'exwm-window-id frame-id)
    (set-frame-parameter frame 'exwm-outer-id outer-id)
    ;; Set urgency flag if it's not appear in the active workspace
    (let ((idx (cl-position original-frame exwm-workspace--list)))
      (when (/= idx exwm-workspace-current-index)
        (set-frame-parameter original-frame 'exwm--urgency t)
        (exwm-workspace--update-switch-history)))
    ;; Fix illegal parameters
    ;; FIXME: check normal hints restrictions
    (let* ((display-width (x-display-pixel-width))
           (display-height (- (x-display-pixel-height)
                              (window-pixel-height (minibuffer-window
                                                    original-frame))
                              (* 2 (window-mode-line-height))
                              (window-header-line-height window)
                              (* 2 exwm-floating-border-width)))
           (display-height (* 2 (/ display-height 2)))) ;round to even
      (if (> width display-width)
          ;; Too wide
          (progn (setq x 0
                       width display-width))
        ;; Invalid width
        (when (= 0 width) (setq width (/ display-width 2)))
        ;; Completely outsize
        (when (or (> x display-width) (> 0 (+ x display-width)))
          (setq x (/ (- display-width width) 2))))
      (if (> height display-height)
          ;; Too tall
          (setq y 0
                height display-height)
        ;; Invalid height
        (when (= 0 height) (setq height (/ display-height 2)))
        ;; Completely outside
        (when (or (> y display-height) (> 0 (+ y display-height)))
          (setq y (/ (- display-height height) 2)))))
    ;; Set OverrideRedirect on this frame
    (xcb:+request exwm--connection
        (make-instance 'xcb:ChangeWindowAttributes
                       :window outer-id :value-mask xcb:CW:OverrideRedirect
                       :override-redirect 1))
    ;; Set event mask
    (xcb:+request exwm--connection
        (make-instance 'xcb:ChangeWindowAttributes
                       :window frame-id :value-mask xcb:CW:EventMask
                       :event-mask xcb:EventMask:SubstructureRedirect))
    ;; Reparent this frame to the original one
    (xcb:+request exwm--connection
        (make-instance 'xcb:ReparentWindow
                       :window outer-id :parent original-id
                       :x (- x exwm-floating-border-width)
                       :y (- y exwm-floating-border-width)))
    ;; Save the geometry
    ;; Rationale: the frame will not be ready for some time, thus we cannot
    ;;            infer the correct window size from its geometry.
    (with-current-buffer (exwm--id->buffer id)
      (setq exwm--floating-edges
            (vector exwm-floating-border-width exwm-floating-border-width
                    (+ width exwm-floating-border-width)
                    (+ height exwm-floating-border-width))))
    ;; Fit frame to client
    (xcb:+request exwm--connection
        (make-instance 'xcb:ConfigureWindow
                       :window outer-id
                       :value-mask (logior xcb:ConfigWindow:Width
                                           xcb:ConfigWindow:Height
                                           xcb:ConfigWindow:StackMode)
                       :width (+ width (* 2 exwm-floating-border-width))
                       :height (+ height (* 2 exwm-floating-border-width)
                                  (window-mode-line-height)
                                  (window-header-line-height))
                       :stack-mode xcb:StackMode:Above)) ;top-most
    ;; Reparent window to this frame
    (xcb:+request exwm--connection
        (make-instance 'xcb:ChangeWindowAttributes
                       :window id :value-mask xcb:CW:EventMask
                       :event-mask xcb:EventMask:NoEvent))
    (xcb:+request exwm--connection
        (make-instance 'xcb:ReparentWindow
                       :window id :parent frame-id
                       :x exwm-floating-border-width
                       :y exwm-floating-border-width))
    (xcb:+request exwm--connection
        (make-instance 'xcb:ChangeWindowAttributes
                       :window id :value-mask xcb:CW:EventMask
                       :event-mask exwm--client-event-mask))
    (xcb:flush exwm--connection)
    ;; Set window/buffer
    (with-current-buffer (exwm--id->buffer id)
      (setq window-size-fixed t         ;make frame fixed size
            exwm--frame original-frame
            exwm--floating-frame frame)
      (set-window-buffer window (current-buffer)) ;this changes current buffer
      (set-window-dedicated-p window t))
    (with-current-buffer (exwm--id->buffer id)
      ;; Some window should not get input focus on creation
      ;; FIXME: other conditions?
      (unless (memq xcb:Atom:_NET_WM_WINDOW_TYPE_UTILITY exwm-window-type)
        (x-focus-frame exwm--floating-frame)
        (exwm-input--set-focus id)))
    (setq exwm-input--focus-lock nil)))

(defun exwm-floating--unset-floating (id)
  "Make window ID non-floating."
  (interactive)
  (setq exwm-input--focus-lock t)
  (let ((buffer (exwm--id->buffer id)))
    ;; Reparent to workspace frame
    (xcb:+request exwm--connection
        (make-instance 'xcb:ChangeWindowAttributes
                       :window id :value-mask xcb:CW:EventMask
                       :event-mask xcb:EventMask:NoEvent))
    (xcb:+request exwm--connection
        (make-instance 'xcb:ReparentWindow
                       :window id
                       :parent (frame-parameter exwm-workspace--current
                                                'exwm-window-id)
                       :x 0 :y 0))      ;temporary position
    (xcb:+request exwm--connection
        (make-instance 'xcb:ChangeWindowAttributes
                       :window id :value-mask xcb:CW:EventMask
                       :event-mask exwm--client-event-mask))
    (xcb:flush exwm--connection)
    (with-current-buffer buffer
      (when exwm--floating-frame        ;from floating to non-floating
        (setq exwm--floating-edges nil) ;invalid by now
        (set-window-dedicated-p (frame-first-window exwm--floating-frame) nil)
        (delete-frame exwm--floating-frame))) ;remove the floating frame
    (with-current-buffer buffer
      (setq exwm--floating-frame nil
            exwm--frame exwm-workspace--current))
    (select-frame exwm-workspace--current t)
    (set-window-buffer nil buffer)
    (exwm-layout--show id)
    (exwm-input--set-focus id))
  (setq exwm-input--focus-lock nil))

(defun exwm-floating-toggle-floating ()
  "Toggle the current window between floating and non-floating states."
  (interactive)
  (with-current-buffer (window-buffer)
    (if exwm--floating-frame
        (exwm-floating--unset-floating exwm--id)
      (exwm-floating--set-floating exwm--id))))

(defvar exwm-floating--moveresize-id nil)
(defvar exwm-floating--moveresize-type nil)
(defvar exwm-floating--moveresize-delta nil)

(defun exwm-floating--start-moveresize (id &optional type)
  "Start move/resize."
  (let ((buffer (exwm--id->buffer id))
        frame frame-id cursor)
    (when (and buffer
               (setq frame (with-current-buffer buffer exwm--floating-frame))
               (setq frame-id (frame-parameter frame 'exwm-outer-id))
               ;; Test if the pointer can be grabbed
               (= xcb:GrabStatus:Success
                  (slot-value
                   (xcb:+request-unchecked+reply exwm--connection
                       (make-instance 'xcb:GrabPointer
                                      :owner-events 0 :grab-window frame-id
                                      :event-mask xcb:EventMask:NoEvent
                                      :pointer-mode xcb:GrabMode:Async
                                      :keyboard-mode xcb:GrabMode:Async
                                      :confine-to xcb:Window:None
                                      :cursor xcb:Cursor:None
                                      :time xcb:Time:CurrentTime))
                   'status)))
      (setq exwm--floating-edges nil)   ;invalid by now
      (with-slots (root-x root-y win-x win-y)
          (xcb:+request-unchecked+reply exwm--connection
              (make-instance 'xcb:QueryPointer :window id))
        (select-frame-set-input-focus frame) ;raise and focus it
        (setq width (frame-pixel-width frame)
              height (frame-pixel-height frame))
        (unless type
          ;; Determine the resize type according to the pointer position
          ;; Clicking the center 1/3 part to resize has not effect
          (setq x (/ (* 3 win-x) (float width))
                y (/ (* 3 win-y) (float height))
                type (cond ((and (< x 1) (< y 1))
                            xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_TOPLEFT)
                           ((and (> x 2) (< y 1))
                            xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_TOPRIGHT)
                           ((and (> x 2) (> y 2))
                            xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_BOTTOMRIGHT)
                           ((and (< x 1) (> y 2))
                            xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_BOTTOMLEFT)
                           ((< y 1) xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_TOP)
                           ((> x 2) xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_RIGHT)
                           ((> y 2) xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_BOTTOM)
                           ((< x 1) xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_LEFT))))
        (when type
          (cond ((= type xcb:ewmh:_NET_WM_MOVERESIZE_MOVE)
                 (setq exwm-floating--moveresize-delta (list win-x win-y 0 0)
                       cursor exwm-floating--cursor-move))
                ((= type xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_TOPLEFT)
                 (setq exwm-floating--moveresize-delta
                       (list win-x win-y (+ root-x width) (+ root-y height))
                       cursor exwm-floating--cursor-top-left))
                ((= type xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_TOP)
                 (setq exwm-floating--moveresize-delta
                       (list 0 win-y 0 (+ root-y height))
                       cursor exwm-floating--cursor-top))
                ((= type xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_TOPRIGHT)
                 (setq exwm-floating--moveresize-delta
                       (list 0 win-y (- root-x width) (+ root-y height))
                       cursor exwm-floating--cursor-top-right))
                ((= type xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_RIGHT)
                 (setq exwm-floating--moveresize-delta
                       (list 0 0 (- root-x width) 0)
                       cursor exwm-floating--cursor-right))
                ((= type xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_BOTTOMRIGHT)
                 (setq exwm-floating--moveresize-delta
                       (list 0 0 (- root-x width) (- root-y height))
                       cursor exwm-floating--cursor-bottom-right))
                ((= type xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_BOTTOM)
                 (setq exwm-floating--moveresize-delta
                       (list 0 0 0 (- root-y height))
                       cursor exwm-floating--cursor-bottom))
                ((= type xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_BOTTOMLEFT)
                 (setq exwm-floating--moveresize-delta
                       (list win-x 0 (+ root-x width) (- root-y height))
                       cursor exwm-floating--cursor-bottom-left))
                ((= type xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_LEFT)
                 (setq exwm-floating--moveresize-delta
                       (list win-x 0 (+ root-x width) 0)
                       cursor exwm-floating--cursor-left)))
          ;; Select events and change cursor (should always succeed)
          (xcb:+request-unchecked+reply exwm--connection
              (make-instance 'xcb:GrabPointer
                             :owner-events 0 :grab-window frame-id
                             :event-mask (logior xcb:EventMask:ButtonRelease
                                                 xcb:EventMask:ButtonMotion)
                             :pointer-mode xcb:GrabMode:Async
                             :keyboard-mode xcb:GrabMode:Async
                             :confine-to xcb:Window:None
                             :cursor cursor
                             :time xcb:Time:CurrentTime))
          (setq exwm-floating--moveresize-id frame-id
                exwm-floating--moveresize-type type))))))

(defun exwm-floating--stop-moveresize (&rest args)
  "Stop move/resize."
  (xcb:+request exwm--connection
      (make-instance 'xcb:UngrabPointer :time xcb:Time:CurrentTime))
  (xcb:flush exwm--connection)
  (setq exwm-floating--moveresize-id nil
        exwm-floating--moveresize-type nil
        exwm-floating--moveresize-delta nil))

(defun exwm-floating--do-moveresize (data synthetic)
  "Perform move/resize."
  (let ((mask 0) (x 0) (y 0) (width 0) (height 0)
        (delta exwm-floating--moveresize-delta)
        obj root-x root-y)
    (when (and exwm-floating--moveresize-id exwm-floating--moveresize-type)
      (setq obj (make-instance 'xcb:MotionNotify))
      (xcb:unmarshal obj data)
      (setq root-x (slot-value obj 'root-x)
            root-y (slot-value obj 'root-y))
      ;; Perform move/resize according to the previously set type
      (cond ((= exwm-floating--moveresize-type
                xcb:ewmh:_NET_WM_MOVERESIZE_MOVE)
             (setq mask (logior xcb:ConfigWindow:X xcb:ConfigWindow:Y)
                   x (- root-x (elt delta 0))
                   y (- root-y (elt delta 1))))
            ((= exwm-floating--moveresize-type
                xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_TOPLEFT)
             (setq mask
                   (logior xcb:ConfigWindow:X xcb:ConfigWindow:Y
                           xcb:ConfigWindow:Width xcb:ConfigWindow:Height)
                   x (- root-x (elt delta 0))
                   y (- root-y (elt delta 1))
                   width (- (elt delta 2) root-x)
                   height (- (elt delta 3) root-y)))
            ((= exwm-floating--moveresize-type
                xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_TOP)
             (setq mask (logior xcb:ConfigWindow:Y xcb:ConfigWindow:Height)
                   y (- root-y (elt delta 1))
                   height (- (elt delta 3) root-y)))
            ((= exwm-floating--moveresize-type
                xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_TOPRIGHT)
             (setq mask
                   (logior xcb:ConfigWindow:Y
                           xcb:ConfigWindow:Width xcb:ConfigWindow:Height)
                   y (- root-y (elt delta 1))
                   width (- root-x (elt delta 2))
                   height (- (elt delta 3) root-y)))
            ((= exwm-floating--moveresize-type
                xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_RIGHT)
             (setq mask (logior xcb:ConfigWindow:Width)
                   width (- root-x (elt delta 2))))
            ((= exwm-floating--moveresize-type
                xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_BOTTOMRIGHT)
             (setq mask
                   (logior xcb:ConfigWindow:Width xcb:ConfigWindow:Height)
                   width (- root-x (elt delta 2))
                   height (- root-y (elt delta 3))))
            ((= exwm-floating--moveresize-type
                xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_BOTTOM)
             (setq mask (logior xcb:ConfigWindow:Height)
                   height (- root-y (elt delta 3))))
            ((= exwm-floating--moveresize-type
                xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_BOTTOMLEFT)
             (setq mask
                   (logior xcb:ConfigWindow:X
                           xcb:ConfigWindow:Width xcb:ConfigWindow:Height)
                   x (- root-x (elt delta 0))
                   width (- (elt delta 2) root-x)
                   height (- root-y (elt delta 3))))
            ((= exwm-floating--moveresize-type
                xcb:ewmh:_NET_WM_MOVERESIZE_SIZE_LEFT)
             (setq mask
                   (logior xcb:ConfigWindow:X xcb:ConfigWindow:Width)
                   x (- root-x (elt delta 0))
                   width (- (elt delta 2) root-x))))
      (xcb:+request exwm--connection
          (make-instance 'xcb:ConfigureWindow
                         :window exwm-floating--moveresize-id :value-mask mask
                         :x x :y y :width width :height height))
      (xcb:flush exwm--connection))))

;; Cursors for moving/resizing a window
(defvar exwm-floating--cursor-move nil)
(defvar exwm-floating--cursor-top-left nil)
(defvar exwm-floating--cursor-top nil)
(defvar exwm-floating--cursor-top-right nil)
(defvar exwm-floating--cursor-right nil)
(defvar exwm-floating--cursor-bottom-right nil)
(defvar exwm-floating--cursor-bottom nil)
(defvar exwm-floating--cursor-bottom-left nil)
(defvar exwm-floating--cursor-left nil)

(defun exwm-floating--init ()
  "Initialize floating module."
  ;; Initialize cursors for moving/resizing a window
  (xcb:cursor:init exwm--connection)
  (setq exwm-floating--cursor-move
        (xcb:cursor:load-cursor exwm--connection "fleur")
        exwm-floating--cursor-top-left
        (xcb:cursor:load-cursor exwm--connection "top_left_corner")
        exwm-floating--cursor-top
        (xcb:cursor:load-cursor exwm--connection "top_side")
        exwm-floating--cursor-top-right
        (xcb:cursor:load-cursor exwm--connection "top_right_corner")
        exwm-floating--cursor-right
        (xcb:cursor:load-cursor exwm--connection "right_side")
        exwm-floating--cursor-bottom-right
        (xcb:cursor:load-cursor exwm--connection "bottom_right_corner")
        exwm-floating--cursor-bottom
        (xcb:cursor:load-cursor exwm--connection "bottom_side")
        exwm-floating--cursor-bottom-left
        (xcb:cursor:load-cursor exwm--connection "bottom_left_corner")
        exwm-floating--cursor-left
        (xcb:cursor:load-cursor exwm--connection "left_side")))



(provide 'exwm-floating)

;;; exwm-floating.el ends here
