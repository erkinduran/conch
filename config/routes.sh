#!/bin/bash

# Route groups: `route_group PREFIX FILE`. Every route of FILE gets PREFIX in front of its
# path, so in routes/api.sh `route GET '/users' ...` answers `/api/users`.
#
# - An empty prefix (or `/`) means no prefix.
# - A file is only loaded for a request whose path starts with its prefix: a request to
#   `/about` never reads routes/api.sh.
# - The longest prefix is tried first, whatever the order here: `/api/v2/users` is looked up
#   in routes/apiv2.sh before routes/api.sh and routes/web.sh.
# - The same file may be given twice, with two prefixes.
#
# Examples
#
#    route_group '/api'    'routes/api.sh'
#    route_group '/api/v2' 'routes/apiv2.sh'
#    route_group '/admin'  'routes/admin.sh'

route_group ''        'routes/web.sh'
route_group '/api'    'routes/api.sh'
