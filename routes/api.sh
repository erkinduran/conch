#!/bin/bash

# Routes under the `/api` prefix (see config/routes.sh): `/users` here is `/api/users`.

route GET  '/users'        'Api/Users' 'index'
route GET  '/users/{id}'   'Api/Users' 'show'
