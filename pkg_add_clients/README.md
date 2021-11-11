The script I use to add (https) clients to my own pkg repository.

See my blog post at [D'un portmaster -a exécuté sur chaque machine à son propre dépôt pkg](https://www.julp.fr/blog/posts/22-d-un-portmaster-a-execute-sur-chaque-machine-a-son-propre-depot-pkg) (written in french) for details.

Usage:

```
pkg_add_clients.sh -r  -j <name of poudriere's jail> -p <name of poudriere's port tree> <name or address of the 1st client to add> <name or address of the 2nd client to add> ... <name or address of the nth client to add>
```
