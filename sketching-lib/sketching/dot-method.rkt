#lang racket/base
(require racket/match racket/list racket/class
         (for-syntax racket/base syntax/parse racket/syntax
                     racket/string
                     "syntax-utils.rkt"))

(provide
 dot/underscore
 dot-field
 declare-struct-fields
 app-dot-method
 define-method
 :=
 ;apply-dot-method
 ; get-dot-method
 ; define-method

 )


;;;
;;; Dot Fields and Methods
;;;

; For a struct Circle defined as:
;     (struct Circle (x y r))
; we would like to write
;     (define c (Circle 10 20 30))
;     (circle c.x c.y c.r)
; in order to draw the circle. Here  circle is the draw-a-circle
; primitive provided by Sketching.

; The value stored in c is a Circle struct, so we need
; associate Circle structs with a set of fields.

; (define-fields Circle Circle? (x y r))

; We can now write:
;    (define (draw-circle c)
;      (circle c.x c.y c.r))


; (here  draw  is called a method).

; To do that we use  define-method:

; (define-method Circle Circle? (draw color)
;   (stroke color)
;   (circle (Circle-x this) (Circle-y this) 


;; (define-method struct-name struct-predicate
;;   (method-name . formals) . more)



;;;
;;; Implementation
;;;

; Each "class" e.g. struct or vector is identified by an unique symbol,
; called the class symbol. 
; For (define-fields Circle Circle? (x y r)) the class symbol will be Circle.
; Each class has a list of fields, here the list of fields are x, y and z.

; Now at runtime  c.x  must called the accessor Circle-x,
; so we also need to store the accessor of each field.

; And later we want to support assignments of the form (:= c.x 10),
; so we also store mutators for the fields.

(struct info (accessor mutator))

; symbol -> (list (cons symbol info) ...)
(define class-symbol-to-fields+infos-ht     (make-hasheq))

(define (add-fields! class-symbol fields accessors mutators)
  ; todo: signal error, if class symbol is in use?
  (define fields+infos (map cons fields (map info accessors mutators)))
  (hash-set! class-symbol-to-fields+infos-ht class-symbol fields+infos))

(define (get-fields+infos class-symbol)
  (hash-ref class-symbol-to-fields+infos-ht class-symbol #f))

(define (find-info fields+infos field)
  (cond
    [(assq field fields+infos) => (λ (x) (cdr x))]
    [else                          #f]))

(define (find-accessor fields+infos field)
  (cond
    [(assq field fields+infos) => (λ (x) (info-accessor (cdr x)))]
    [else                          #f]))

(define (find-mutator fields+infos field)
  (cond
    [(assq field fields+infos) => (λ (x) (info-mutator (cdr x)))]
    [else                          #f]))


; In an expression like  c.x  the identifier c is bound to
; a value. To get from the value to the class symbol, we
; need some predicates.


(define class-symbol-to-predicate-ht     (make-hasheq)) ; symbol -> (value -> boolean)
(define predicate-to-class-symbol-assoc  '())           ; (list (cons predicate symbol) ...)


(define (add-predicate! class-symbol predicate)
  (hash-set! class-symbol-to-predicate-ht class-symbol predicate)
  (set! predicate-to-class-symbol-assoc
        (cons (cons predicate class-symbol)
              predicate-to-class-symbol-assoc)))

(define (find-class-symbol value)
  (let loop ([as predicate-to-class-symbol-assoc])
    (cond
      [(empty? as) #f]      ; the value has no associated class symbol
      [else        (define predicate+symbol (car as))
                   (define predicate        (car predicate+symbol))
                   (if (predicate value)
                       (cdr predicate+symbol)
                       (loop (cdr as)))])))

(define (find-class-symbol+predicate value)
  (let loop ([as predicate-to-class-symbol-assoc])
    (cond
      [(empty? as) (values #f #f)]  ; the value has no associated class symbol
      [else        (define predicate+symbol (car as))
                   (define predicate        (car predicate+symbol))
                   (if (predicate value)
                       (values (cdr predicate+symbol) predicate)
                       (loop (cdr as)))])))

; Finally we need address how  c.x  eventually evaluates as (Circle-x c).
; Since  c.x  isn't bound in our program, the expander expands
; c.x into (#%top c.x). In "main.rkt" we have defined a
; #%sketching-top, which will be used as #%top by programs
; written in the Sketching language.

; In #%sketching-top we detect that the unbound identifier contains
; a dot, and we can then expand it into:
;   (dot-field c x)
; The naive implementation of  dot-field will expand into:

;; (let ()
;;   (define class-symbol     (find-class-symbol c))
;;   (define fields+accessors (get-fields+accessors class-symbol))
;;   (define accessor         (find-accessor fields+accessors 'x))
;;   (accessor c))

; However, if c.x is being used in a loop where c runs through a series of circles,
; then it is a waste of time to search for the same class symbol and accessor
; each time. Instead we can cache the accessor (and a predicate) so we can reuse
; the next time. The predicate is used to check that we got a value of the
; same time as last - if not, then we need to look for the new class.

; Note: The first design used . for both field access and for vector/string indexing.
;       Expanding into  (if (object? obj) (get-field field obj) (vector-ref obj field))
;       leads to an unbounded reference (at compile time) when object.field is compiled,

;; Syntax classes for the separators.

(begin-for-syntax
  (define-syntax-class dot        #:datum-literals (|.|) (pattern |.|))
  (define-syntax-class underscore #:datum-literals (|_|) (pattern |_|))
  (define-syntax-class separator (pattern (~or _:dot _:underscore))))
  

(define-syntax (dot/underscore stx)
  (syntax-parse stx
    [(_dot/underscore object:id)
     #'object]
    [(_dot/underscore object:id sep:dot field:id)
     (with-syntax
       ([cached-accessor  (syntax-local-lift-expression #'#f)]  ; think: (define cached-accessor #f) 
        [cached-predicate (syntax-local-lift-expression #'#f)]) ;        is added at the top-level
       #'(let ()            
           (define accessor
             (cond
               [(and cached-predicate (cached-predicate object))
                cached-accessor]
               [(object? object)
                (set! cached-accessor  (λ (obj) (get-field field obj)))
                (set! cached-predicate object?)
                cached-accessor]
               [else
                (define-values (class-symbol predicate) (find-class-symbol+predicate object))
                (define fields+infos                    (get-fields+infos class-symbol))
                (define a                               (find-accessor fields+infos 'field))
                (set! cached-accessor  a)
                (set! cached-predicate predicate)
                (or a (raise-syntax-error 'dot/underscore "object does not have this field" #'object #'field))]))
           (accessor object)))]
    [(_dot/underscore object:id sep:underscore index)
     (with-syntax
       ([cached-accessor  (syntax-local-lift-expression #'#f)]  ; think: (define cached-accessor #f) 
        [cached-predicate (syntax-local-lift-expression #'#f)]) ;        is added at the top-level
       #'(let ()            
           ; problem: if the index is a bound in a for-clause, then
           ;          lifting the expression won't work - since `for`
           ;          doesn't mutate the variable
           ; fix:     ? comment out
           ; sigh...               
           #;(define accessor
             (cond
               [(and cached-predicate (cached-predicate object))
                cached-accessor]
               [(vector? object)
                  (set! cached-accessor  (λ (obj) (vector-ref obj index)))
                  (set! cached-predicate vector?)                
                  cached-accessor]
               [(string? object)
                  (set! cached-accessor  (λ (obj) (string-ref obj index)))
                  (set! cached-predicate string?)
                  cached-accessor]
               [else
                (set! cached-accessor  #f)
                (set! cached-predicate #f)
                (raise-syntax-error 'dot/underscore "value is not indexable with underscore" #'stx)]))
           #;(accessor object)
           (define obj object)
           (cond
             [(vector? obj) (vector-ref obj index)]
             [(string? obj) (string-ref obj index)]
             [else (error 'underscore "value is not indexable with underscore" obj)])))]
  [(_dot/underscore object:id (~seq sep field-or-index) ... last-sep last-field-or-index)
   (syntax/loc stx
     (let ([t (dot/underscore object (~@ sep field-or-index) ...)])
       (dot/underscore t last-sep last-field-or-index)))]))


(define-syntax (dot-field stx)
  (syntax-parse stx
    [(_dot-field object:id)
     (syntax/loc stx
       object)]
    [(_dot-field object:id field:id)
     (with-syntax
       ([cached-accessor  (syntax-local-lift-expression #'#f)]  ; think: (define cached-accessor #f) 
        [cached-predicate (syntax-local-lift-expression #'#f)]) ;        is added at the top-level
       #'(let ()            
           (define accessor
             (cond
               [(and cached-predicate (cached-predicate object))
                cached-accessor]
               [(object? object)
                (set! cached-accessor  (λ (obj) (get-field field obj)))
                (set! cached-predicate object?)
                cached-accessor]
               [else
                (define-values (class-symbol predicate) (find-class-symbol+predicate object))
                (define fields+infos                    (get-fields+infos class-symbol))
                (define a                               (find-accessor fields+infos 'field))
                (set! cached-accessor  a)
                (set! cached-predicate predicate)
                (or a (raise-syntax-error 'dot-field 
                                          (string-append "object does not have this field "
                                                         (symbol->string (syntax-e #'object))
                                                         (symbol->string (syntax-e #'field)))
                                          #'stx))]))
           (accessor object)))]
  [(_dot-field object:id field:id ... last-field:id)
   (syntax/loc stx
     (let ([t (dot-field object field ...)])
       (dot-field t last-field)))]))

(define-syntax (under-index stx)
  (syntax-parse stx
    [(_under-index object:id index) ; index is id or number
     (with-syntax
       ([cached-accessor  (syntax-local-lift-expression #'#f)]  ; think: (define cached-accessor #f) 
        [cached-predicate (syntax-local-lift-expression #'#f)]) ;        is added at the top-level
       #'(let ()            
           (define accessor
             (cond
               [(and cached-predicate (cached-predicate object))
                cached-accessor]
               [(vector? object)
                (set! cached-accessor  (λ (obj) (vector-ref obj index)))
                (set! cached-predicate vector?)
                cached-accessor]
               [(string? object)
                (set! cached-accessor  (λ (obj) (string-ref obj index)))
                (set! cached-predicate string?)
                cached-accessor]
               [else
                (set! cached-accessor  #f)
                (set! cached-predicate #f)
                (raise-syntax-error 'under-index "value is not indexable with underscore" #'stx)]))
           (accessor object)))]
  [(_under-index object:id index ... last-index)
   (syntax/loc stx
     (let ([t (under-index object index ...)])
       (under-index t last-index)))]))

(define-syntax (assign-dot/underscore stx)
  (syntax-parse stx
    ; assign value to object field
    [(_assign-dot/underscore object:id sep:dot field:id e:expr)
     (with-syntax ([cached-mutator   (syntax-local-lift-expression #'#f)]
                   [cached-predicate (syntax-local-lift-expression #'#f)])
       (syntax/loc stx
         (let ()
           (define mutator
             (cond
               [(and cached-predicate (cached-predicate object))
                cached-mutator]
               [(object? object)  
                (set! cached-mutator  (λ (obj v) (set-field! field obj v)))
                (set! cached-predicate object?)
                cached-mutator]               
               [else
                (define-values (class-symbol predicate) (find-class-symbol+predicate object))
                (define fields+infos                    (get-fields+infos class-symbol))
                (define m                               (find-mutator fields+infos 'field))
                (set! cached-mutator   m)
                (set! cached-predicate predicate)
                (unless m
                  (raise-syntax-error ':= "object does not have this field: ~a" (syntax-e #'field)))
                m]))
           (mutator object e))))]
    [(_assign-dot/underscore object:id sep:dot not-a-field e:expr)
     (raise-syntax-error ':= "field name (i.e. an identifier) expected after the dot"
                         stx)]
    ; assign value to vector slot
    [(_assign-dot/underscore object:id sep:underscore index:expr e:expr)
     (with-syntax ([cached-mutator   (syntax-local-lift-expression #'#f)]
                   [cached-predicate (syntax-local-lift-expression #'#f)])
       (syntax/loc stx
         (let ()
           (define mutator
             (cond
               [(and cached-predicate (cached-predicate object))
                cached-mutator]
               [(vector? object)
                (set! cached-mutator  (λ (obj v) (vector-set! obj index v)))
                (set! cached-predicate vector?)
                cached-mutator]
               [else
                (raise-syntax-error ':= "underscore expects the object to be a vector" #'stx)]))
           (mutator object e))))]
    
    [(_assign-dot/underscore object:id (~seq sep:separator field-or-index) ... 
                             last-sep:separator last-field-or-index e:expr)
     (syntax/loc stx
       (let ([w e] [t (dot/underscore object (~@ sep field-or-index) ...)])
         (assign-dot/underscore t last-sep last-field-or-index w)))]))

;; (define name-used-as-index   142)
;; (define number-used-as-field 242)
;; (define field-is-unbound     343)

#;(define-syntax (dot-assign-field stx)
  (syntax-parse stx
    [(_dot-assign-field object:id field-or-index e:expr)
     (define index-used? (number? (syntax-e #'field-or-index)))
     (define field-is-bound?
       (and (identifier? #'field-or-index) ; #f means index  
            (identifier-binding #'field-or-index 0)))
     ; If info is #f, we will treat field-or-index as an unbound identifier.
     ; If unbound we know that the identifier is not an index - and we
     ; must make sure we don't reference it in the vector fall back.
     ; If unbound field-as-index refers to a dummy identifier.
     
     (with-syntax ([cached-mutator   (syntax-local-lift-expression #'#f)]
                   [cached-predicate (syntax-local-lift-expression #'#f)]
                   [stx stx]
                   [field       (if index-used? #'number-used-as-field #'field-or-index)]
                   [index       (if index-used? #'field-or-index       #'name-used-as-index)]
                   [index-used? index-used?])
       (with-syntax ([field-as-index (if field-is-bound? #'field #'field-is-unbound)])
       #'(let ()
           (define mutator
             (cond
               [(and cached-predicate (cached-predicate object))
                cached-mutator]
               [(object? object)  
                (set! cached-mutator  (λ (obj v) (set-field! field obj v)))
                (set! cached-predicate object?)
                cached-mutator]
               [(and index-used? (vector? object))
                (set! cached-mutator  (λ (obj v) (vector-set! obj index v)))
                (set! cached-predicate vector?)
                cached-mutator]
               [else
                (define-values (class-symbol predicate) (find-class-symbol+predicate object))
                (define fields+infos                    (get-fields+infos class-symbol))
                (define m                               (find-mutator fields+infos 'field))
                (set! cached-mutator  m)
                (set! cached-predicate predicate)
                (cond
                  [m                  m]
                  [(vector? object)   (define m (λ (obj v) (vector-set! obj field-as-index v)))
                                      (set! cached-mutator   #f) ; can't cache the index can change
                                      (set! cached-predicate #f)
                                      m]
                  [else
                   (raise-syntax-error 'dot-field "object does not have this field" #'stx)])]))
           (mutator object e))))]
    [(_dot-field object:id field-or-index ... last-field e:expr)
     (syntax/loc stx
       (let ([w e] [t (dot-field object field-or-index ...)])
         (dot-assign-field t last-field w)))]))

;;;
;;; Defining class with fields
;;;

; We would like to write:
;     (declare-struct-fields Circle Circle? (x y r))
; to declare that the Circle "class" has fields x, y and r.

; The general form is:
;     (declare-struct-fields class-symbol predicate (field ...))

(define-syntax (declare-struct-fields stx)
  (syntax-parse stx
    [(_declare-struct-fields struct-name:id predicate:id (field:id ...))
     (with-syntax ([class-symbol #'struct-name]
                   [(accessor ...)
                    (for/list ([f (syntax->list #'(field ...))])
                      (format-id f "~a-~a" #'struct-name f))]
                   [(mutator ...)
                    (for/list ([f (syntax->list #'(field ...))])
                      (format-id f "set-~a-~a!" #'struct-name f))])
       (syntax/loc stx
         (begin
           (add-predicate! 'class-symbol predicate)
           (add-fields! 'class-symbol '(field ...)
                        (list accessor ...)
                        (list mutator  ...)))))]))
                               

;;;
;;; Assignment
;;;

;; (define str (symbol->string (syntax-e #'top-id)))
;; (cond
;;   [(string-contains? str ".")
;;    (define ids (map string->symbol (string-split str ".")))
;;    (with-syntax ([(id ...) (for/list ([id ids])
;;                              (datum->syntax #'top-id id))])
;;      #'(dot-field id ...))]
;;   [else
;;    #'(#%top . top-id)])

; (:= v.i.j 42)
; (vector-set! (vector-ref v i) j 42)

#;(begin-for-syntax
  (define (stringify x #:mode [mode 'convert])
    (cond
      [(string? x)     x]
      [(char? x)       (string x)]
      [(symbol? x)     (symbol->string x)]
      [(number? x)     (number->string x)]      
      [(identifier? x) (symbol->string (syntax-e x))]
      [else            #f]))

  (define (id-contains? id needle)
    (string-contains? (stringify id) (stringify needle)))

  (define (split-id id sep [context id] [prop #f])
    ; note: context is either #f or a syntax object
    ;       prop    is either #f or a syntax object
    (cond
      [(not (id-contains? id sep)) id]
      [else                        
       (define strs (string-split (stringify id) (stringify sep)))
       (define srcloc id)
       (for/list ([str strs])
         (define sym (string->symbol str))
         (datum->syntax context sym srcloc prop))])))

(define-syntax (:= stx)
  (syntax-parse stx
    [(_ x:id e)     
     (cond
       [(or (id-contains? #'x ".") (id-contains? #'x "_"))
        (with-syntax ([(id ...) (map number-id->number (split-id-at-dot/underscore #'x))])
          (syntax/loc stx
            (assign-dot/underscore id ... e)))]
       #;[(id-contains? #'x ".")
          (define xs (map number-id->number (split-id #'x ".")))
          (with-syntax ([(x ...) xs])
            (syntax/loc stx
              (dot-assign-field x ... e)))]
       [else
        (syntax/loc stx
          (set! x e))])]
    [(_ v:id e1 e2)
     (syntax/loc stx
       (let ()
         (when (vector? v)
           (define i e1)
           (when (and (integer? i) (not (negative? i)))
             (vector-set! v i e2)))))]))


;; (define-syntax (:= stx)
;;   (syntax-parse stx
;;     [(_ x:id e)
;;      (define str (symbol->string (syntax-e #'x)))
;;      (cond
;;        [(string-contains? str ".")
;;         (define ids (map string->symbol (string-split str ".")))
;;         (with-syntax ([(x ...) (for/list ([id ids])
;;                                  (datum->syntax #'x id))])
;;             (syntax/loc stx                                 
;;               (dot-assign-field x ... e)))]
;;        [else
;;         (syntax/loc stx
;;           (set! x e))])]
;;     [(_ v:id e1 e2)
;;      (syntax/loc stx
;;        (let ()
;;          (when (vector? v)
;;            (define i e1)
;;            (when (and (integer? i) (not (negative? i)))
;;              (vector-set! v i e2)))))]))



;;;
;;; Methods
;;;

; For a struct Circle defined as:

;     (struct Circle (x y r))

; we would like to write

;     (define c (Circle 10 20 30))
;     (define-method Circle (draw this color)
;        (stroke color)
;        (circle this.x this.y this.r))
;     (c.draw "red")

; in order to draw the circle.

; The method draw of the class Circle is called as (c.draw "red")
; and turns into (Circle-draw c "red").

(struct minfo (procedure)) ; "method onfo"

; symbol -> (list (cons symbol minfo) ...)
(define class-symbol-to-methods+minfos-ht (make-hasheq))

(define (add-method! class-symbol method procedure)  
  (define methods+minfos (hash-ref class-symbol-to-methods+minfos-ht class-symbol '()))  
  (define method+minfo   (cons method (minfo procedure)))
  (hash-set! class-symbol-to-methods+minfos-ht class-symbol (cons method+minfo methods+minfos)))

(define (get-methods+minfos class-symbol)
  (hash-ref class-symbol-to-methods+minfos-ht class-symbol #f))

(define (find-method-procedure methods+minfos method)
  (cond
    [(assq method methods+minfos) => (λ (x) (minfo-procedure (cdr x)))]
    [else                            #f]))


(define-syntax (app-dot-method stx)
  (syntax-parse stx
    [(_app-dot-method (object:id method:id) . args)
     (with-syntax
       ([cached-procedure (syntax-local-lift-expression #'#f)] ; think: (define cached-procedure #f) 
        [cached-predicate (syntax-local-lift-expression #'#f)] ;        is added at the top-level
        [stx stx])
       #'(let ()
           (define procedure
             (cond
               [(and cached-predicate (cached-predicate object)) cached-procedure]
               [(object? object)
                ; XXX
                (set! cached-predicate object?)
                (set! cached-procedure (λ (obj . as)
                                         ;(displayln (list 'obj obj))
                                         ;(displayln (list 'args args))
                                         (send/apply obj method as)))
                cached-procedure]
               [else
                (define-values (class-symbol predicate) (find-class-symbol+predicate object))
                (define methods+minfos                  (get-methods+minfos class-symbol))
                (define p                               (find-method-procedure methods+minfos 'method))
                (set! cached-procedure p)
                (set! cached-predicate predicate)
                (unless p
                  (raise-syntax-error 'app-dot-methods "object does not have this method" #'stx))
                p]))
           (procedure object . args)))]
    [(_app-dot-field (object:id field:id ... method:id) . args)
     (syntax/loc stx
       (let ([obj (dot-field object field ...)])
         (app-dot-method (obj method) . args)))]))


(define-syntax (define-method stx)
  (syntax-parse stx
    [(_define-method struct-name:id (method-name:id . formals) . more)
     (with-syntax ([struct-predicate (format-id stx "~a?"   #'struct-name)]
                   [struct-method    (format-id stx "~a-~a" #'struct-name #'method-name)]
                   [this             (format-id stx "this")])
       (syntax/loc stx
         (begin
           (define (struct-method this . formals) . more)
           (add-predicate! 'struct-name struct-predicate)
           (add-method! 'struct-name 'method-name struct-method))))]))


;;;
;;; Builtin "classes"
;;;

(add-predicate! 'vector vector?)
(add-predicate! 'list   list?)
(add-predicate! 'string string?)

(define vector-ref*
  (case-lambda
    [(this i1)       (vector-ref this i1)]
    [(this i1 i2)    (vector-ref (vector-ref this i1) i2 )]
    [(this i1 i2 i3) (vector-ref (vector-ref (vector-ref this i1) i2) i3)]
    [else (error 'vector-ref* "only 3 indices supported")]))

;;; Builtin fields for builtin "classes"
(add-fields! 'vector '(ref length x y z)             
             (list vector-ref*
                   vector-length
                   (λ (v) (vector-ref v 0))
                   (λ (v) (vector-ref v 1))
                   (λ (v) (vector-ref v 2)))
             (list #f
                   #f
                   (λ (v e) (vector-set! v 0 e))
                   (λ (v e) (vector-set! v 1 e))
                   (λ (v e) (vector-set! v 2 e))))

(add-fields! 'list '(x y z)
             (list first second third)
             (list #f    #f     #f))



(add-method! 'vector 'length vector-length)
(add-method! 'vector 'ref    vector-ref*)
(add-method! 'vector 'list   vector->list)
(add-method! 'vector 'fill!  vector-fill!)
(add-method! 'vector 'values vector->values)

(add-method! 'list 'length  length)
(add-method! 'list 'ref     list-ref)
(add-method! 'list 'vector  list->vector)

(add-method! 'string 'length  string-length)
(add-method! 'string 'ref     string-ref)
(add-method! 'string 'list    string->list)




;; ;;;
;; ;;; Methods
;; ;;; 

;; (hash-set*! class-symbol-to-methods-ht
;;             'vector
;;             (make-methods-ht 'length vector-length
;;                              'ref    vector-ref
;;                              'list   vector->list
;;                              'fill!  vector-fill!
;;                              'values vector->values)
;;             'list
;;             (make-methods-ht 'length length
;;                              'ref    list-ref
;;                              'vector list->vector
;;                              'values (λ (xs) (apply values xs)))
;;             'string
;;             (make-methods-ht 'length string-length
;;                              'ref    string-ref
;;                              'list   string->list)
;;             ; unknown class
;;             #f (make-hasheq))



;; (define class-symbol-to-methods-ht    (make-hasheq))

;; (define (make-methods-ht . args)
;;   (define key-methods
;;     (let loop ([args args])
;;       (match args
;;         [(list* key method more)
;;          (cons (cons key method)
;;                (loop more))]
;;         ['()
;;          '()])))
;;   (make-hasheq key-methods))




;; (define (predicates->symbol x)
;;  ...)  

;; (define (value->class-symbol v)
;;   (cond
;;     [(vector? v) 'vector]
;;     [(list?   v) 'list]
;;     [(string? v) 'string]
    
;;     [else        #f]))

;; (define-syntax (apply-dot-method stx)
;;   (syntax-parse stx
;;     [(_get object:id method-name:id more ...)
;;      #'(let ()
;;          (define class   (value->class-symbol object))         
;;          (define methods (hash-ref class-symbol-to-methods-ht class #f))
;;          (define method  (hash-ref methods 'method-name ))         
;;          (method object more ...))]))


;; (define-syntax (get-dot-method stx)
;;   (syntax-parse stx
;;     [(_get object:id method-name:id)
;;      #'(let ()
;;          (define cached-method    #f)
;;          (define cached-predicate #f)
;;          (λ args
;;            (define method
;;              (cond
;;                [(and cached-predicate (cached-predicate object)) cached-method]
;;                [else
;;                 (define class (value->class-symbol object))
;;                 (displayln (list 'class class))
;;                 (define p     (hash-ref class-symbol-to-predicates-ht class #f))
;;                 (displayln (list 'p p))
;;                 (define ms    (hash-ref class-symbol-to-methods-ht    class #f))
;;                 (displayln (list 'ms ms))
;;                 (define m     (hash-ref ms 'method-name))
;;                 (displayln (list 'm m))
;;                 (set! cached-predicate p)
;;                 (set! cached-method m)
;;                 m]))
;;            (apply method (cons object args))))]))


;; (define-syntax (define-method stx)
;;   (syntax-parse stx
;;     [(_define-method struct-name:id struct-predicate:id
;;         (method-name:id . formals)
;;         . more)
;;      (with-syntax ([struct-method (format-id stx "~a-~a" #'struct-name #'method-name)])
;;        (syntax/loc stx
;;          (begin
;;            (define (struct-method this . formals) . more)
;;            (hash-set*! class-symbol-to-predicates-ht 'struct-name struct-predicate)
;;            (define ht (hash-ref class-symbol-to-methods-ht 'struct-name #f))
;;            (unless ht
;;              (define new-ht (make-hasheq))
;;              (hash-set! class-symbol-to-methods-ht 'struct-name new-ht)
;;              (set! ht new-ht))
;;            (hash-set! ht 'method-name struct-method)
;;            (displayln " -- ")
;;            (displayln class-symbol-to-methods-ht)
;;            (newline)
;;            (displayln ht) (newline)
           
;;            )))]))
     


;; ;; (define-syntax (#%top stx)
;; ;;   (display ".")
;; ;;   (syntax-parse stx
;; ;;     [(_ . s:id) #'id]))
  

;; ;; (struct Circle (x y r c))

;; ;; ;; (define-method Circle (draw C [color "red"])
;; ;; ;;   (fill color)
;; ;; ;;   (circle C.x C.y C.r))
  

;; ;; ; (obj.name foo bar) => (mehthod foo

;; ;; (define c (Circle 10 20 30 "white"))

;; ;c.x
