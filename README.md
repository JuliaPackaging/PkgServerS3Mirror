# PkgServerS3Mirror

A combined [`PkgServer.jl`](https://github.com/JuliaPackaging/PkgServer.jl) and `nginx`-based S3 mirror!  Copy `.env.example` to `.env`, edit its values (after you've got DNS pointing in the right place) and then type `make`!

# The Art of Deployment

What follows is a guide to how `@staticfloat` likes to organize his dev-ops work.  This should serve as a simple, opinionated, methodology toward creating reliable, medium-scale deployments of services.  We'll start with the big picture, work our way down into how to build the individual pieces, then how to combine them together, and finally return back to the big picture to see how a new commit gets tested, built, and deployed.

## The Big Picture, part one

The end result that we want to arrive at is a group of dockerized services, each solving a single problem and each auto-updating as their base configuration is updated.  While a running deployment may look like a single, monolithic entity, it will in reality be a gestalt of small containers, each of which will have some combination of `code`, `configuration`, `meta-code` and `state` baked within it.  To define these terms:

* `code`: This is the beating heart of the service.  For a webserver, this might be the `nginx` executable and all its libraries.  For `PkgServer.jl`, it's all the Julia code in `bin/` and `src/`.  This code should be _identical_ across all installations, and if the code gets updated, all deployments should immediately upgrade to the latest version of the `code`.

* `configuration`: This is things like setting the `server_name` within an nginx config to tell it what HTTPS hostname to respond to; or giving an application the password to a database.  These values are deployment-specific and often sensitive.  The `code` should be expecting to receive `configuration` where applicable (reading config files, environment variables, etc...), and should either explicitly fail if it's missing, or have intelligent defaults.  For `PkgServer.jl`, this is the `.env` file that is placed within the `deployment/` directory, and the `docker-compose.yml` files that define the service deployment within docker.

* `meta-code`: This is code that is run upon deployment.  We want to minimize this as much as possible, and use it only as a last resort.  For `PkgServer.jl` this is the `Makefile` that is run from within `deployment/` that makes it easier to use `docker-compose.yml`.  All it does is create directories as mountpoints and choose between SSL/non-SSL deployments.

* `state`: This is content that gets generated/stored over the course of the service's lifetime.  Databases, caches, etc...  For `PkgServer.jl` this is the package caches.

As we architect our application, we will be breaking the pieces of functionality down into as small of pieces as possible, putting those inside Docker containers, hooking them up to eachother, and defining the appropriate boundaries of `code`, `configuration`, `meta-code` and `state` to get a cohesive, resilient architecture.  Let's go ahead and dive into an example of how this can be done.  Again, we'll use `PkgServer.jl` as our example.

## Building Dockerized Services

The fundamental unit we'll work with is a container.  Each container will typically contain a single, master process, such as `julia`, or `nginx`, or `python`.  It will have its own view of the filesystem, have its own set of ports it can listen on, and will usually communicate with other processes only through the network.  This simultaneously builds some small security/accident protections into our processes (`rm -rf /` will only wipe out a single container, not everything on the server) as well as gives us the easy ability to move containers across multiple machines (changing the `configuration` but not the `code`).

To build a container, we first start with some code and define a recipe (known as a `Dockerfile`) for how to build an environment that can run our code.  There are many guides on how to write `Dockerfile`s so I won't waste time with it here.  I will, however, point out some things that make using docker slightly more fun when working in an interactive fashion.  Here's the [`PkgServer.jl` `Dockerfile`](https://github.com/JuliaPackaging/PkgServer.jl/blob/master/Dockerfile), broken down into steps with commentary:

```dockerfile
FROM julia:1.3

# This Dockerfile must be built with a context of the top-level PkgServer.jl directory
WORKDIR /app

# We're going to try and make this runnable as any UID, so install packages to /depot
RUN mkdir /depot
ENV JULIA_DEPOT_PATH="/depot"
```

When running a docker container, it runs with its own UID and GID, which can be configurable, but must obey the permissions encoded within the container.  Consequently, we choose to install Julia packages to a location where we then rewrite the permissions to be readable and writable by anyone, so that we can run this container with any UID.  This allows us to have the actual cached files available for inspection by the current user, instead of having `docker` write out cached files that are unreadable by the current user:

```dockerfile
# Copy in Project.toml/Manifest.toml, instantiate immediately, so that we don't have to do this
# every time we rebuild, since those files should change relatively slowly.
ADD *.toml /app/
RUN julia --project=/app -e "using Pkg; Pkg.instantiate(); Pkg.precompile()"
RUN chmod 777 -R /depot/compiled
```

Note that we first `ADD` the `Project.toml` and `Manifest.toml` files and then instantiate/precompile the entire project.  We expect the `Project.toml` and `Manifest.toml` files to change somewhat slowly, and so we make sure to run this before copying in the rest of the application source code (which should change much more quickly, during development) so that the work of instantiation and precompiling dependencies does not have to be done every time we re-build the docker container.

```dockerfile
# Our default command is to run the pkg server with the bundled `run_server.jl` script
CMD ["julia", "--project=/app", "/app/bin/run_server.jl"]

# Next, copy in full `PkgServer.jl` directory (this is the step that will most often be invalidated)
ADD . /app
```
Finally, we copy in all our own source code and give the `Dockerfile` a default command.  Note that while many other Dockerfiles may add extra metadata such as `EXPOSE 8000` (to declare that port 8000 should be exposed to the outside world) or `VOLUME /app/cache` (to declare that a volume should be mounted there to host the cached data we'll be writing out), all those hints will be ignored when we use higher-level orchestration tools such as `docker-compose`, so I do not bother to embed them within most of my `Dockerfile`s.

## Linking Multiple Dockerized Services Together

My favorite tool of choice to link dockerized services together is [`docker-compose`](https://docs.docker.com/compose/).  It's simple, it has no real dependencies beyond `docker` and a python package, and it can run on one machine or orchestrate an entire swarm.  It's perfect for quickly downloading and deploying something on a machine with a minimum of setup.  There is an example embedded within this repository, the file [`docker-compose.yml`](docker-compose.yml).  While again, there are many resources for learning exactly how to put one of these together, I will go over a few high-level items:

* We deploy three services: `frontend`, `pkgserver` and `watchtower`.  The `frontend` is an nginx SSL terminator, while `pkgserver` is the julia process that performs the actual application logic, and `watchtower` is an auto-update docker container that we will discuss more later.

* Each service feeds from an upstream docker image: `frontend` uses `staticfloat/nginx-certbot`, while `pkgserver` uses `juliapackaging/pkgserver.jl`, etc... This drives a clear isolation between the `code` and the `configuration`: we do not use the ability of `docker-compose` to build new docker images on the host for three reasons: First, it adds unnecessary complexity (and can be difficult to combine with automatic deployment).  Secondly, it doesn't let us use nice tools like [`watchtower`](https://github.com/containrrr/watchtower) which automatically pull down new images when they are built on docker hub.  Lastly, it forces us to encode this separation explicitly by using configuration files or environment variables to pass `configuration` to the container, rather than patching the `code` or other such evils.  A core tenent of automatic deployment is that the `code` should never be customized; only `configuration`.

* Volumes are used to allow for persistent data; the containers can be restarted at any time, and their root filesystems can change out from underneath the application due to image updates.  All `state` gets placed within these volumes so that they can be lifecycled independently of the `code` and `configuration`.

* We use a bare minimum of `meta-code` here, just a simple `Makefile` to make running the `docker-compose` commands more palatable, and also to script a few useful things like ensuring some directories are created with the proper permissions before `docker-compose up` is run.

## Testing Dockerized Services

Once we have a container system setup and running, we want to make sure it is testable.  This is another good test for how to split up your application into small pieces; you should separate things into logical units for testing.  In this case, the bare minimum testable unit is the PkgServer code itself; we want to be able to verify that it is, in fact, capable of serving tarballs, that the files get cached on-disk properly, that a docker deployment works, etc...  And so we define a `.travis.yml` setup that launches the Julia process directly, as well as within a `docker` environment (exactly as we would in production), and ensure that the responses and the files on-disk are what we expect them to be.  We do no test things like HTTPS availability, or the ability to auto-upgrade because those pieces are handled by separate containers; we define a natural separation of tasks, test each task in isolation, and rely on higher-level testing for the integration tests that include things like the HTTPS terminator and the auto-update functionality.

## Automatically Deploying Dockerized Services

In order to automatically deploy a dockerized service, we make two simple design decisions:  First, only `code` is automatically updated, secondly all `code` gets built and pushed to Docker Hub.  By making these two design decisions, we are able to use tools like [`watchtower`](https://github.com/containrrr/watchtower) to automatically update our docker container base images when they are updated.  To get things pushed to Docker Hub automatically, we set our repository up on Docker Hub and provide the `Dockerfile` within the git repository such that every new push to `master` results in a new docker image built.  And that's it.  It really is that simnple.

Our workflow therefore looks like this:

* Code change is proposed in a PR, modifying the `code` functionality a bit.

* Tests run within the PR, ensuring that the `code` works, typically with some base example `configuraiton` applied.

* Once tests pass, the code is merged, triggering a new build on Docker Hub.

* All `watchtower` instances eventually notice that a new image is available on Docker Hub, and they pull down a new version of the image that they are serving.

Because the only action being run on the deployed servers is to download and launch a new docker container, if we have confidence that the docker container works, this should be a very low-risk maneuver.  We gain this confidence through thorough automated testing before anything is merged into `master`.  This workflow disallows any kind of local modifications to `code`, and makes `meta-code` very difficult to write if it interacts with the `code` in any significant way, as docker images may be getting replaced left and right.  The only way to be certain this system will work well is if your entire application can be brought from the ground up frmo scratch with the configuration options applied through config files and environment variables in your `docker-compose` file.
