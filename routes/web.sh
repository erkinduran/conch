#!/bin/bash

# Routes: `route METHOD /path Controller action`, tried in order, the first match wins.
# A `{name}` segment is available to the action as `ROUTE_PARAMETERS[name]`.

route GET  '/'             'Home' 'index'
route GET  '/hello/{name}' 'Home' 'hello'
route GET  '/users'        'Users' 'index'
route GET  '/users/{id}'   'Users' 'show'
route POST '/users'        'Users' 'store'
