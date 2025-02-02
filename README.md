# foveated-metamers

Create metamers using models of the ventral stream and run experiments
to validate them

This project starts with a replication of Freeman and Simoncelli,
2011, out to higher eccentricities, and will extend it by looking at
spatial frequency information as well.

# Dockerfile

In order to build Dockerfile, have this directory and the most recent
version of `plenoptic` in the same directory and then FROM THAT
DIRECTORY (the one above this one), run `sudo docker build
--tag=foveated-metamers:YYYY-MM-dd -f foveated-metamers/Dockerfile
--compress .`. This ensures that we can copy plenoptic over into the
Docker container.

Once we get plenoptic up on pip (or even make it public on github), we
won't need to do this. At that time, make sure to replace
`foveated-metamers/environment.yml` with `environment.yml` and remove
the plenoptic bit.

Once image is built, save it to a gzipped tarball by the following:
`sudo docker save foveated-metamers:YYYY-MM-dd | gzip >
foveated-metamers_YYYY-MM-dd.tgz` and then copy to wherever you
need it.

# Requirements

This has only been tested on Linux, both Ubuntu 18.04 and
Fedora 29. It will probably work with minimal to no changes on OSX,
but there's no guarantee, and we definitely don't support Windows.

Need to make sure you have ffmpeg on your path when creating the metamers, so
make sure it's installed and on your path. I have had a lot of trouble using
`module` to load the ffmpeg present on NYU prince, and so recommend installing
[a static build](https://www.johnvansickle.com/ffmpeg/faq/) and using that
directly (note that I have not had this problem with NYU greene or Flatiron
Institute's rusty, so it appears to be cluster-specific).

For demosaicing the raw images we use as inputs, you'll need to
install [dcraw](https://www.dechifro.org/dcraw/). If you're on Linux,
you can probably install it directly from your package manager. See
these [instructions](http://macappstore.org/dcraw/) for OSX. If you're
fine using the demosaiced `.tiff` files we provide, then you won't
need it.

Both provided conda environment files pin the versions of all the
python packages required to those used for the experiment. That's
probably not necessary, but is provided as a step to improve
reproducibility. We provide built Docker images for the same reason: 

If you're using GPUs to create images, you'll also need `dotlockfile`
on your machine in order to create the lockfiles we use to prevent
multiple jobs using the same GPU.

TODO: ADD DOCKER IMAGES

Other requirements:
- inkscape, at least version 1.0.2

## Experiment environment

For running the experiment, need to install `glfw` from your package
manager.

There are two separate python environments for this project: one for
running the experiment, and one for everything else. To install the
experimental environment, either follow [the minimal
install](#minimal-experiment-install) or do the following:

```
conda env create -f environment-psychopy.yml
```

Then, to activate, run `conda activate psypy`.

PsychoPy provides multiple backends. I'm now using the `pyglet` backend, but
I've occasionally had issues with a weird [`XF86VidModeGetGammaRamp failed`
error](https://github.com/psychopy/psychopy/issues/2061). If you get that error
and are unable to fix it, switching to the `glfw` backend will probably work (if
you followed the above install instructions, you'll have the requirements for
both on your machine). I've also had issues with `glfw` where it doesn't record
the key presses before the pause and run end during the experiment, which means
those trials aren't counted and may mess up how `analysis.summarize_trials`
determines which keypress corresponds to which trial. If you switch to `glfw`,
you should carefully check that.

## Environment everything else

To setup the environment for everything else:

```
git submodule sync
git submodule update --init --recursive
conda env create -f environment.yml
```

Then, to activate, run `conda activate metamers`.

The [plenoptic
library](https://github.com/LabForComputationalVision/plenoptic/) is
not yet on `pip`, so you'll have to download it manually (at that
link), then (in the `metamers` environment), navigate to that
directory and install it:

```
git clone git@github.com:LabForComputationalVision/plenoptic.git
cd plenoptic
pip install -e .
```

This environment contains the packages necessary to generate the
metamers, prepare for the experiment, and analyze the data, but it
*does not* contain the packages necessary to run the experiment. Most
importantly, it doesn't contain Psychopy, because I've found that
package can sometimes be a bit trickier to set up and is not necessary
for anything outside the experiment itself.

## Source images

We use images from the authors' personal collection and the [UPenn Natural Image
Database](http://tofu.psych.upenn.edu/~upennidb/) as the targets for our metamer
generation. This is because we need images that are large, linear (i.e., their
pixel intensities are proportional to photon count, as you get from an image
that has not been processed in any way), and openly-licensed. See the
[Setup](#setup) section for details on how to obtain the images from the Open
Science Foundation website for this project, along with the statistics used to
normalize the V1 model and a small image of Albert Einstein for testing the
setup.

Authors' personal collection: 
- WFB: azulejos, tiles, bike, graffiti, llama, terraces
- EPS: ivy, nyc, rocks, boats, gnarled, lettuce

UPenn Natural Image Database: treetop (cd01A/DSC_0033), grooming
(cd02A/DSC_0011), palm (cd02A/DSC_0043), leaves (cd12A/DSC_0030), portrait
(cd58A/DSC_0001), troop (cd58A/DSC_0008).

Unpublished photos from David Brainard: quad (EXPOSURE_ASC/DSC_0014), highway
(SNAPSHOTS/DSC_0200).

## Minimal experiment install

If you just want to run the experiment and you want to install the
minumum number of things possible, the following should allow you to
run this experiment. Create a new virtual environment and then:

```
pip install psychopy==3.1.5 pyglet==1.3.2 numpy==1.17.0 h5py==2.9.0 glfw==1.8.2
```

And then if you're on Linux, fetch the wxPython wheel for you platform
from [here](https://extras.wxpython.org/wxPython4/extras/linux/gtk3/)
(for my setup, I used `wxPython-4.0.6-cp37-cp37m-linux_x86_64.whl`;
the `cp37` refers to python 3.7, I'm pretty sure, so that's very
important; not sure if the specific version of wxPython matters) and
install it with `pip install path/to/your/wxpython.whl`.

Everything should then hopefully work.

# Data dictionaries

Several pandas DataFrames are created during the course of this
experiment and saved as `.csv` files. In order to explain what the
different fields they have mean, I've put together some data
dictionaries, in the `data_dictionaries` directory. I tried to follow
[these
guidelines](https://help.osf.io/hc/en-us/articles/360019739054-How-to-Make-a-Data-Dictionary)
from the OSF. They are `.tsv` files and so can be viewed in Excel,
Google Sheets, a text editor, LibreOffice Calc, or loaded in to pandas
(`data_dict = pd.read_csv(data_dictionaries/metamer_summary.tsv,
'\t')`)

 - `metamer_summary.tsv`: during metamer synthesis, we save out a
   `summary.csv` file, which contains a DataFrame with one row,
   describing the metamer generated and some information about its
   synthesis. This data dictionary describes the columns in that
   DataFrame.
   
 - `all_metamer_summary.tsv`: in order to create the indices that determine the
   trias in the experiment, we gather together and concatenate all the
   `summary.csv` files, then save the resulting DataFrame as
   `stimuli_description.csv`. This data dictionary describes that DataFrame's
   columns, which are identical to those in `summary.csv`.
   
- `experiment_df.tsv`: in order to analyze the data, we want to
  examine the images presented in each trial, what the correct answers
  was, and what button the subject pressed. We do this using
  `experiment_df.csv`, which we create for each experimental session
  (in a given session, one subject will see all trials for a given
  model; each subject, session pair has a different random seed used
  to generate the presentation index). Most of the DataFrame can be
  generated before the experiment is run (but after the index has been
  generated), but the final four columns (`subject_response,
  hit_or_miss, subject_name and session_number`) are only added when
  combining the subject's response information with the pre-existing
  `experiment_df`. We have two separate functions in `stimulus.py` for
  generating the DataFrame with and without subject response info, but
  we only save the completed version to disk.
  
- `summary_df.tsv`: In order to plot our psychophysical curves, we
  want to get the proportion of correct responses in each
  condition. That's what this summary DataFrame contains. This is the
  "least combined" way of looking at it: we have not collapsed across
  images, trial types, sessions, or, subjects (the `n_trials` column
  will be useful to correctly weight the average if you want to
  collapse across them).
  
## Additional data

`data/Dacey1992_RGC.csv` contains data from figure 2B of Dennis M. Dacey and
Michael R. Petersen (1992), "Dendritic field size and morphology of midget and
parasol ganglion cells of the human retina", PNAS 89, 9666-9670, extracted using
[WebPlotDigitizer](https://apps.automeris.io/wpd/) on July 15, 2021. To recreate
that figure, using the snakemake rule `dacey_figure`. Note that we did not
separate the data into nasal field and temporal, upper, and lower fields, as the
paper does.

# Code structure

 - `Snakefile`: used by snakemake to determine how to create the files for this
   project. Handles everything except the experiment
 - `foveated_metamers/`: library of functions used in this project
    - `create_metamers.py`: creates metamers.
    - `stimuli.py`: assembles the various metamer images into format required
      for running the experiment.
    - `distances.py`: finds distance in model space between images in an
      efficient way.
    - `experiment.py`: runs experiment.
    - `analysis.py`: basic analyses of behavioral data.
    - `curve_fit.py`: fits psychophysical curves to real or simulated data.
    - `simulate.py`: simulate behavioral data, for checking `curve_fit.py`
      performance, as well as how many trials are required.
    - `figures.py`: creates various figures.
    - `utils.py`: various utility functions.
  - `extra_packages/`: additional python code used by this repo. The bits that
    live here were originally part of
    [plenoptic](https://github.com/LabForComputationalVision/plenoptic/), but
    were pulled out because it's a bad idea for a research project to be so
    heavily reliant on a project currently under development.
    - `pooling-windows`: git submodule that points to [this
      repo](https://github.com/LabForComputationalVision/pooling-windows),
      containing the pooling windows we use.
    - `plenoptic_part`: contains the models and metamer synthesis code (as well
      as some utilities) that were pulled out of plenoptic, branching at [this
      commit](https://github.com/LabForComputationalVision/plenoptic/tree/fb1c4d29c645c9a054baa021c7ffd07609b181d4)
      (I used [git filter-repo](https://github.com/newren/git-filter-repo/) and
      so the history should be preserved). While the model code (and some of the
      utilities) have been deleted from `plenoptic` and are unique to this repo,
      the synthesis code here is a modified version of the one in plenoptic. If
      you wish to use synthesis for your own work *use the plenoptic version*,
      which is regularly tested and supported.
  - `notebooks/`: jupyter notebooks for investigating this project in more
    detail.
    - `Freeman_Check.ipynb`: notebook checking that our windows are the same
      size as those from Freeman and Simoncelli, 2011 (and thus that the models'
      scaling parameter has the same meaning); see
      [below](#check-against-freeman-and-simoncelli-2011-windows) for more
      details.

# Usage

The general structure of the research project this repo describes is
as follows:

1. Develop models of the early visual system
2. Generate metamers for these models
3. Use psychophysics to set model parameters

The code for the models and general metamer synthesis are contained in the
[plenoptic library](https://github.com/LabForComputationalVision/plenoptic/);
this repo has four main components: generate metamers (2), prepare for the
experiment (3), run the experiment (3), and analyze the data from the experiment
(3). How to use this repo for each of those tasks is described below.

I use the [Snakemake](https://snakemake.readthedocs.io/en/stable/)
workflow management tool to handle most of the work involved in
generating the metamers, preparing for the experiment, and analyzing
the experiment output, so for everything except running the experiment
itself, you won't call the python scripts directly; instead you'll
tell `snakemake` the outputs you want, and it will figure out the
calls necessary, including all dependencies. This simplifies things
considerably, and means that (assuming you only want to run things,
not to change anything) you can focus on the arguments to `snakemake`,
which specify how to submit the jobs rather than making sure you get
all the arguments and everything correct.

## Setup

Make sure you've set up the software environment as described in the
[requirements](#requirements) section and activate the `metamers`
environment: `conda activate metamers`.

In order to generate these metamers in a reasonable time, you'll need
to have GPUs availabe. Without it, the code will not work; it could be
modified trivially by replacing the `gpu=1` with `gpu=0` in the
`get_all_metamers` function at the top of `Snakefile`, but generating
all the metamers would take far too much time to be
realistic. Additionally, PyTorch [does not
guarantee](https://pytorch.org/docs/stable/notes/randomness.html)
reproducible results between CPU and GPU executions, even with the
same seed, so you generating metamers on the CPU will not result in an
identical set of images, though (assuming the loss gets low enough),
they should still be valid metamers.

Decide where you want to place the metamers and data for this
project. For this README, it will be
`/home/billbrod/Desktop/metamers`. Edit the first line of the
`config.yml` file in this repo to contain this value (don't use the
tilde `~` for your home directory, python does not understand it, so
write out the full path).

Create that directory, download the tarball containing the reference
images and normalizing statistics, and unzip it into that directory:

```
mkdir /home/billbrod/Desktop/metamers
cd /home/billbrod/Desktop/metamers
wget -O- https://osf.io/td3ea/download | tar xvz -C .
```

You should now have three directories here: `raw_images`, `ref_images` and
`norm_stats`. `raw_images` should contain four `.NEF` (Nikon's raw format)
images: `azulejos`, `flower`, `tiles`, and `market`. `norm_stats` should contain
a single `.pt` (pytorch) file: `V1_texture_degamma_norm_stats.pt`. `ref_images`
should contain `einstein_size-256,256.png`, which we'll use for testing the
setup, as well as `.tiff` versions of the four raw images (the raw images are
provided in case you want to try a different demosaicing algorithm than the one
I did; if you're fine with that step, you can ignore them and everything further
will use the `.tiff` files found in `ref_images`).

## Test setup

A quick snakemake rule is provided to test whether your setup is
working: `snakemake -j 4 -prk test_setup_all`. This will create a small number
of metamers, without running the optimization to completion. If this
runs without throwing any exceptions, your environment should be set
up correctly and you should have gpus available.

The output will end up in `~/Desktop/metamers/test_setup` and you can
delete this folder after you've finished.

## Check against Freeman and Simoncelli, 2011 windows

This project uses a modification of the pooling windows first described in
Freeman and Simoncelli, 2011. We include some code to check our reimplementation
of the windows and the extension to use Gaussians instead of raised-cosine
falloffs. Basically, we want to make sure that our windows are the same size --
identical reimplementation is not important, but we want to make sure that the
models' scaling parameter has the same interpretation; it should be the ratio
between the eccentricity and the radial diameter of the windows at half-max
amplitude. To do so, we include a notebook `notebooks/Freeman_Check.ipynb`, as
well as some snakemake rules.

We check two things: that our windows' scaling parameter has the same meaning as
that in the original paper, and that our V1 metamers look approximately the
same. You can view this by looking at the `Freeman_Check` notebook and its
cached outputs directly. If you wish to run the notebook or investigate the
objects in more detail, you can run either the `freeman_check` or
`download_freeman_check` snakemake rules (`freeman_check` will run the analyses
and so requires matlab and a GPU, while `download_freeman_check` will just
download the outputs of this from the [OSF](https://osf.io/67tbe/)):

``` sh
conda activate metamers
snakemake -prk download_freeman_check
# OR
snakemake -prk freeman_check
```

Once you've done that, you can start up the jupyter notebook. There are two main
ways of getting jupyter working so you can view the included notebook:

1. Install jupyter in this `metamers` environment: 

``` sh
conda activate metamers
conda install -c conda-forge jupyterlab
```

   This is easy but, if you have multiple conda environments and want to use
   Jupyter notebooks in each of them, it will take up a lot of space.
   
2. Use [nb_conda_kernels](https://github.com/Anaconda-Platform/nb_conda_kernels):

``` sh
# activate your 'base' environment, the default one created by miniconda
conda activate 
# install jupyter lab and nb_conda_kernels in your base environment
conda install -c conda-forge jupyterlab
conda install nb_conda_kernels
# install ipykernel in the calibration environment
conda install -n metamers ipykernel
```

   This is a bit more complicated, but means you only have one installation of
   jupyter lab on your machine.
   
In either case, to open the notebooks, navigate to the `notebooks/` directory on
your terminal and activate the environment you install jupyter into (`metamers`
for 1, `base` for 2), then run `jupyter` and open up the notebook. If you
followed the second method, you should be prompted to select your kernel the
first time you open a notebook: select the one named "metamers".

## Generate metamers

Generating the metamers is very time consuming and requires a lot of
computing resources. We generate 108 images per model (4 reference
images * 3 seeds * 9 scaling values), and the amount of time/resources
required to create each image depends on the model and the scaling
value. The smaller the scaling value, the longer it will take and the
more memory it will require. For equivalent scaling values, V1
metamers require more memory and time than the RGC ones, but the RGC
metamers required for the experiment all have much smaller scaling
values. For the smallest of these, they require too much memory to fit
on a single GPU, and thus the length it takes increases drastically,
up to about 8 hours. For the V1 images, the max is about three
hours. -- TODO: UPDATE THESE ESTIMATES

The more GPUs you have available, the better.

If you wanted to generate all of your metamers at once, this is very
easy: simply running

```
python foveated_metamers/utils.py RGC V1 -g --print | xargs snakemake -j n --resources gpu=n mem=m -prk --restart-times 3 --ri 
```

will do this (where you should replace both `n` with the number of
GPUs you have; this is how many jobs we run simultaneously; assuming
everything is working correctly, you could increase the `n` after `-j`
to be greater than the one after `--resources gpu=`, and snakemake
should be able to figure everything out; you should also replace `m`
with the GB of RAM you have available). `snakemake` will create the
directed acyclic graph (DAG) of jobs necessary to create all metamers.

However, you probably can't create all metamers at once on one machine, because
that would take too much time. You probably want to split things up. If you've
got a cluster system, you can configure `snakemake` to work with it in a
[straightforward
manner](https://snakemake.readthedocs.io/en/stable/executable.html#cluster-execution)
(snakemake also works with cloud services like AWS, kubernetes, but I have no
experience with that; you should google around to find info for your specific
job scheduler, see the small repo [I put
together](https://github.com/billbrod/snakemake-slurm) for using NYU's or the
Flatiron Institute's SLURM system). In that case, you'll need to put together a
`cluster.json` file within this directory to tell snakemake how to request GPUs,
etc (see `greene.json` and `rusty.json` for the config files I use on NYU's and
Flatiron's, respectively). Something like this should work for a SLURM system
(the different `key: value` pairs would probably need to be changed on different
systems, depending on how you request resources; the one that's probably the
most variable is the final line, gpus):

```
{
    "__default__":
    {
	"nodes": 1,
	"tasks_per_node": 1,
	"mem": "{resources.mem}GB",
	"time": "36:00:00",
	"job_name": "{rule}.{wildcards}",
	"cpus_per_task": 1,
	"output": "{log}",
	"error": "{log}",
	"gres": "gpu:{resources.gpus}"
    }
}
```

Every `create_metamers` job will use a certain number of gpus, as
given by `resources.gpu` for that job. In the snippet above, you can
see that we use it to determine how many gpus to request from the job
scheduler. On a local machine, `snakemake` will similarly use it to
make sure you don't run five jobs that require 1 gpus each if you only
have 4 gpus total, for example. Similarly, `resources.mem` provides an
estimate of how much memory (in GB) the job will use, which we use
similarly when requesting resources above. This is just an estimate
and, if you find yourself running out of RAM, you may need to increase
it in the `get_mem_estimate` function in `Snakefile.`

If you don't have a cluster available and instead have several machines with
GPUs so you can split up the jobs, making use of the
`foveated_metamers/utils.py` script. See it's help string for details, but
calling it from the command line with different arguments will generate the
paths for the corresponding metamers. For example, to generate all RGC metamers
with a given scaling value, you would run 

```
python foveated_metamers/utils.py RGC -g --print --scaling 0.01
```

The `-g` argument tells the script to include the gamma-correction step (for
viewing on non-linear displays), `--print` tells it to print out the desired
output (instead of saving it to file), and `RGC` and `--scaling 0.01` tell it to
use that model and scaling value, respectively. While messing with this, pay
attention to the `-j n` and `--resources gpu=n` flags, which tell snakemake how
many jobs to run at once and how many GPUs you have available, respectively.

Note that I'm using dotlockfile to handle scheduling jobs across
different GPUs. I think this will work, but I recommend adding the
`--restart-times 3` flag to the snakemake call, as I do above, which
tells snakemake to try re-submitting a job up to 3 times if it
fails. Hopefully, the second time a job is submitted, it won't have a
similar problem. But it might require running the `snakemake` command
a small number of times in order to get everything straightened out.

## Prepare for experiment

Once the metamers have all been generated, they'll need to be combined
into a numpy array for the displaying during the experiment, and the
presentation indices will need to generated for each subject.

For the experiment we performed, we had XX subjects, with 6 sessions per model
(2 image blocks, with 4 reference images each, by 3 presentation orders). In
order to re-generate the indices we used, you can simply run `snakemake -prk
gen_all_idx`. This will generate the indices for each subject, each session,
each model, as well as the stimuli array (we actually use the same index for
each model for a given subject and session number; they're generated using the
same seed).

This can be run on your local machine, as it won't take too much time
or memory.

The stimuli arrays will be located at:
`~/Desktop/metamers/stimuli/{model_name}/stimuli_comp-{comp}.npy` and the presentation
indices will be at
`~/Desktop/metamers/stimuli/{model_name}/task-split_comp-{comp}/{subj_name}/{subj_name}_task-split_comp-{comp}_idx_sess-{sess_num}_im-{im_num}.npy`,
where `{comp}` is `met` and `ref`, for the metamer vs metamer and metamer vs
reference image comparisons, respectively. There will also be a pandas
DataFrame, saved as a csv, at
`~/Desktop/metamers/stimuli/{model_name}/stimuli_description.csv`, which
contains information about the metamers and their optimization. It's used to
generate the presentation indices as well as to analyze the data.

You can generate your own, novel presentation indices by running `snakemake -prk
~/Desktop/metamers/stimuli/{model_name}/task-split_comp-{comp}/{subj_name}/{subj_name}_task-split_comp-{comp}_idx_sess-{sess_num}_im-{im_num}.npy`,
replacing `{model_name}` with one of `'RGC_norm_gaussian',
'V1_norm_s6_gaussian'`, `{subj_name}` must be of the format `sub-##`, where `##`
is some integer (ideally zero-padded, but this isn't required), `{sess_num}`
must also be an integer (this is because we use the number in the subject name
and session number to determine the seed for randomizing the presentation order;
if you'd like to change this, see the snakemake rule `generate_experiment_idx`,
and how the parameter `seed` is determined; as long as you modify this so that
each subject/session combination gets a unique seed, everything should be fine),
`{im_num}` is `00` or `01` (determines which set of 4 reference images are
shown), and `comp` take one of the values explained above.

### Demo / test experiment

For teaching the subjects about the task, we have two brief training runs: one
with noise images and one with a small number of metamers. To put them together,
run `snakemake -prk
~/Desktop/metamers/stimuli/training_noise/task-split_comp-met/sub-training/sub-training_task-split_comp-met_idx_sess-00_im-00.npy
~/Desktop/metamers/stimuli/training_RGC_norm_gaussian/task-split_comp-met/sub-training/sub-training_task-split_comp-met_idx_sess-00_im-00.npy
~/Desktop/metamers/stimuli/training_V1_norm_s6_gaussian/task-split_comp-met/sub-training/sub-training_task-split_comp-met_idx_sess-00_im-00.npy`.
This will make sure the stimuli and index files are created. Then run the
[training](#training) section below.

## Run experiment

To run the experiment, make sure that the stimuli array and presentation indices
have been generated and are at the appropriate path. It's recommended that you
use a chin-rest or bite bar to guarantee that your subject remains fixated on
the center of the image; the results of the experiment rely very heavily on the
subject's and model's foveations being identical.

We want 6 sessions per subject per model. Each session will contain all trials
in the experiment for 4 of the 8 reference images, the only thing that differs
is the presentation order (each subject gets presented a different split of 4
reference images). 

### Training

To teach the subject about the experiment, we want to introduce them to the
structure of the task and the images used. The first one probably only needs to
be done the first time a given subject is collecting data for each model, the
second should be done at the beginning of each session.

1. First, run a simple training run (make sure the stimuli and indices are
   created, as described [above](#demo--test-experiment)):
    - `conda activate psypy` 
    - `python foveated_metamers/experiment.py ~/Desktop/metamers/stimuli/training_noise/stimuli_comp-{comp}.npy sub-training 0 -s 0 -c {comp} ; python foveated_metamers/experiment.py ~/Desktop/metamers/stimuli/training_{model}/stimuli_comp-{comp}.npy sub-training 0 -s 0 -c {comp}` 
       where `{comp}` is `met` or `ref`, depending on which version you're
       running, and `{model}` is `RGC_norm_gaussian` or `V1_norm_s6_gaussian`,
       depending on which you're running.
    - Explanatory text will appear on screen, answer any questions.
    - This will run two separate training runs, both about one or two minutes,
      each followed by feedback. 
    - The first one will just be comparing natural to noise images and so the
      subject should get 100%. The goal of this one is to explain the basic
      structure of the experiment.
    - The second will have two metamers, one easy and one hard, for each of two
      reference images. They should get 100% on the easy one, and do worse on
      the hard. The goal of this one is to show what the task is like with
      metamers and give them a feeling for what they may look like.
2. Run: 
   - `conda activate metamers`
   - `python example_images.py {model} {subj_name} {sess_num}` where `{model}`
     is `V1` or `RGC` depending on which model you're running, and `{subj_name}`
     and `{sess_num}` give the name of the subject and number of this session,
     respectively.
   - This will open up three image viewers. Each has all 5 reference images the
     subject will see this session. One shows the reference images themselves,
     one the metamers with the lowest scaling value, and one the metamers with
     the highest scaling value (all linear, not gamma-corrected).
    - Allow the participant to flip between these images at their leisure, so
      they understand what the images will look like.

### Split-screen Task

Now, using a split-screen task. Each trial lasts 1.4 seconds and is structured
like so:

```
|Image 1 | Blank  |Image 2 |Response|  Blank |
|--------|--------|--------|--------|--------|
|200 msec|500 msec|200 msec|        |500 msec|
```

Image 1 will consist of a single image divided vertically at the center by a
gray bar. One half of image 2 will be the same as image 1, and the other half
will have changed. The two images involved are either two metamers with the same
scaling value (if `comp=met`) or a metamer and the reference image it is based
on (if `comp=ref`). The subject's task is to say whether the left or the right
half changed. They have as long as they need to respond and receive no feedback.

To run the experiment:

- Activate the `psypy` environment: `conda activate psypy`
- Start the experiment script from the command line: 
   - `python foveated_metamers/experiment.py ~/Desktop/metamers/stimuli/{model}/stimuli_comp-{comp}.npy {subj_name} {sess_num} -c {comp}` 
     where `{model}, {subj_name}, {sess_num}, {comp}` are as described in the
     [training](#training) section.
   - There are several other arguments the experiment script can take,
     run `python foveated_metamers/experiment.py -h` to see them, and
     see the [other arguments](#other-arguments) section for more
     information.
- Explain the task to the subject, as seen in the "say this to subject for
  experiment" section (similar text will also appear on screen before each run
  for the participant to read)
- When the subject is ready, press the space bar to begin the task.
- You can press the space bar at any point to pause it, but the pause
  won't happen until the end of the current trial, so don't press it a
  bunch of times because it doesn't seem to be working. However, try
  not to pause the experiment at all.
- You can press q/esc to quit, but don't do this unless truly
  necessary.
- There will be a break half-way through the block. The subject can
  get up, walk, and stretch during this period, but remind them to
  take no more than a minute. When they're ready to begin again,
  press the space bar to resume.
- The data will be saved on every trial, so if you do need to quit out, all is
  not lost. If you restart from the same run, we'll pick up where we left off.
- The above command will loop through all five runs for a given session. To do a
  particular set of runs pass `-r {run_1} {run_2} ... {run_n}` to the call to
  `experiment.py` (where `{run_1}` through `{run_n}` are 0-indexed integers
  specifying the runs to include). For example, if you quit out on the third run
  and wanted to finish that one and then do runs 4 and 5, pass: `-r 2 3 4`. If
  you just want to finish that run, you'd only pass `-r 2`.

Recommended explanation to subjects:

> In this experiment, you'll be asked to complete what we call an "2-Alternative
> Forced Choice task": you'll view an image, split in half, and then, after a
> brief delay, a second image, also split in half. One half of the second image
> will be the same as the first, but the other half will have changed. Your task
> is to press the left or right button to say which half you think changed. All
> the images will be presented for a very brief period of time, so pay
> attention. Sometimes, the two images will be very similar; sometimes, they'll
> be very different. For the very similar images, we expect the task to be hard.
> Just do your best!

> You'll be comparing natural and synthesized images. The first image can be
> either natural or synthesized, so pay attention! You will receive no feedback,
> either during or after the run.

> For this experiment, fixate on the center of the image the whole time and try
> not to move your eyes.

> The run will last for about twelve minutes, but there will be a break halfway
> through. During the break, you can move away from the device, walk around, and
> stretch, but please don't take more than a minute. 

This part will not be shown on screen, and so is important:

> You'll complete 5 runs total. After each run, there will be a brief pause, and
> then the instruction text will appear again, to start the next run. You can
> take a break at this point, and press the spacebar when you're ready to begin
> the next run.

### Other arguments

The `experiment.py` takes several optional arguments, several of which
are probably relevant in order to re-run this on a different
experiment set up:

- `--screen` / `-s`: one integer which indicate which screens
  to use. 
- `--screen_size_pix` / `-p`: two integers which indicate the size of
  the screen(s) in pixels .
- `--screen_size_deg` / `-d`: a single float which gives the length of
  the longest screen side in degrees.

For more details on the other arguments, run `python
foveated_metamers/experiment.py -h` to see the full docstring.

NOTE: While the above options allow you to run the experiment on a setup that
has a different screen size (both in pixels and in degrees) than the intended
one, the metamers were created with this specific set up in mind. Things should
be approximately correct on a different setup (in particular, double-check that
images are cropped, not stretched, when presented on a smaller monitor), but
there's no guarantee. If you run this experiment, with these stimuli, on a
different setup, my guess is that the psychophysical curves will look different,
but that their critical scaling values should approximately match; that is,
there's no guarantee that all scaling values will give images that will be
equally confusable on different setups, but the maximum scaling value that leads
to 50% accuracy should be about the same. The more different the viewing
conditions, the less likely that this will hold.

### Checklist

The following is a checklist for how to run the experiment. Print it out and
keep it by the computer.

Every time:

1. Make sure monitor is using the correct icc profile (`linear-profile`;
   everything should look weirdly washed out). If not, hit the super key (the
   Windows key on a Windows keyboard) and type `icc`, open up the color manager
   and enable the linear profile.
   
First session only (on later sessions, ask if they need a refresher):
   
2. Show the participant the set up and show the participants the wipes and say
   they can use them to wipe down the chinrest and button box.
   
3. Tell the participant:

> In this task, a natural image will briefly flash on screen, followed by a gray
> screen, followed by another image. Half of that second image will be the same
> as the first, half will have changed. Your task is to say which half has
> changed, using these buttons to say "left" or "right". You have as long as
> you'd like to respond, and you will not receive feedback. There will be a
> pause halfway through, as well as between runs; take a break and press the
> center button (labeled "space") to continue when you're ready. You won't press
> the buttons in the bottom row.

4. Train the participant. Say:

> Now, we'll do two brief training runs, each of which will last about a minute.
> In the first, you'll be comparing natural images and noise; the goal is so you
> understand the basic structure of the experiment. In the second, you'll be
> comparing those same natural images to some of the stimuli from the
> experiment; some will be easy, some hard. You'll receive feedback at the end
> of the run, to make sure you understand the task. I'll remain in the room to
> answer any questions.
>
> There will be fixation dot in the center of some explanatory text at the
> beginning, use that to center yourself.

5. Run (replace `{model}` with `V1_norm_s6_gaussian` or `RGC_norm_gaussian`):

``` sh
conda activate psypy
python foveated_metamers/experiment.py ~/Desktop/metamers/stimuli/training_noise/stimuli_comp-ref.npy sub-training 0 -c ref ; python foveated_metamers/experiment.py ~/Desktop/metamers/stimuli/training_{model}/stimuli_comp-ref.npy sub-training 0 -c ref
```

6. Answer any questions.

Every time:

7. Show the participant the images they'll see this session, replacing `{model}`
   with `V1` or `RGC` (no need to use the full name), and `{subj_name}` and
   `{sess_num}` as appropriate:

``` sh
conda activate metamers
python example_images.py {model} {subj_name} {sess_num}
```

8. Say the following and answer any questions:

> These are the natural images you'll be seeing this session, as well as some
> easy and hard stimuli. You can look through them for as long as you'd like.
 
9. Ask if they have any questions before the experiment.

10. Say:

> This will run through all 5 runs for this session. Each should take you 10 to
> 12 minutes. Come get me when you're done. As a reminder, you have as long as
> you'd like to respond, and you won't receive any feedback.

10. Run, replacing `{model}`, `{subj_name}`, `{sess_num}` as above:

``` sh
conda activate psypy
python foveated_metamers/experiment.py ~/Desktop/metamers/stimuli/{model}/stimuli_comp-ref.npy {subj_name} {sess_num} -c ref
```

## Analyze experiment output

*In progress*

# Known issues

1. When using multiprocessing (as done when fitting the psychophysical curves)
   from the command-line, I get `OMP: Error #13: Assertion faliure at
   z_Linux_util.cpp(2361)` on my Ubuntu 18.04 laptop. As reported
   [here](https://github.com/ContinuumIO/anaconda-issues/issues/11294), this is
   a known issue, and the solution appears to be to set an environmental
   variable: running `export KMP_INIT_AT_FORK=FALSE` in the open terminal will
   fix the problem. Strangely, this doesn't appear to be a problem in a Jupyter
   notebook, but it does from `IPython` or the `snakemake` calls. I tried to set
   the environmental variable from within Snakefile, but I can't make that work.
   Running the calls with `use_multiproc=False` will also work, though it will
   obviously be much slower.
2. When trying to use the `embed_bitmaps_into_figure` rule on a drive mounted
   using `rclone` (I had my data stored on a Google Drive that I was using
   `rclone` to mount on my laptop), I got a `'Bad file descriptor'` error from
   python when it tried to write the snakemake log at the end of the step. It
   appears to be [this
   issue](https://forum.rclone.org/t/bad-file-descriptor-when-moving-files-to-rclone-mount-point/13936),
   adding the `--vfs-cache-mode writes` flag to the `rclone mount` command
   worked (though I also had to give myself full permissions on the rclone cache
   folder: `sudo chmod -R 777 ~/.cache/rclone`).

# References

- Freeman, J., & Simoncelli, E. P. (2011). Metamers of the ventral
  stream. Nature Neuroscience, 14(9),
  1195–1201. http://dx.doi.org/10.1038/nn.2889

