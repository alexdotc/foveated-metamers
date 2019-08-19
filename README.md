# foveated-metamers

Create metamers using models of the ventral stream and run experiments to validate them

This project starts with a replication of Freeman and Simoncelli,
2011, out to higher eccentricities, and will extend it by looking at
spatial frequency information as well.

# Dockerfile

In order to build Dockerfile, have this directory and the most recent
version of `plenoptic` in the same directory and then FROM THAT
DIRECTORY (the one above this one), run `sudo docker build
--tag=foveated-metamers:YYYY-MM-dd -f foveated-metamers/Dockerfile
.`. This ensures that we can copy plenoptic over into the Docker
container.

Once we get plenoptic up on pip (or even make it public on github), we
won't need to do this. At that time, make sure to replace
`foveated-metamers/environment.yml` with `environment.yml` and remove
the plenoptic bit.

Once image is built, save it to a gzipped tarball by the following:
`sudo docker save foveated-metamers:YYYY-MM-dd | gzip >
foveated-metamers_YYYY-MM-dd.tar.gz` and then copy to wherever you
need it.

# Requirements

Need to make sure you have ffmpeg on your path when creating the
metamers, so make sure it's installed.

When running on NYU's prince cluster, can use `module load
ffmpeg/intel/3.2.2` or, if `module` isn't working (like when using the
`fish` shell), just add it to your path manually (e.g., on fish: `set
-x PATH /share/apps/ffmpeg/3.2.2/intel/bin $PATH`)

For running the experiment, need to install `glfw` from your package
manager.

we use the
[LIVE-NFLX-II](http://live.ece.utexas.edu/research/LIVE_NFLX_II/live_nflx_plus.html)
data set to get some input images. We provide those in our
[ref_images](https://osf.io/5t4ju) tarball, but the link is presented
here if you wish to examine the rest of the data set.

## Minimal experiment install

If you just want to run the experiment and you want to install the
minumum number of things possible, the following should allow you to
run this experiment. Create a new virtual environment and then:

```
pip install psychopy==3.1.5 pyglet==1.3.2 numpy h5py glfw
```

And then if you're on Linux, fetch the wxPython wheel for you platform
from [here](https://extras.wxpython.org/wxPython4/extras/linux/gtk3/)
and install it with `pip install path/to/your/wxpython.whl`.

Everything should then hopefully work.

# References

- Freeman, J., & Simoncelli, E. P. (2011). Metamers of the ventral
  stream. Nature Neuroscience, 14(9),
  1195–1201. http://dx.doi.org/10.1038/nn.2889
