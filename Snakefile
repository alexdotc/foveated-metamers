import os.path as op
from glob import glob

configfile:
    "config.yml"
if not os.path.isdir(config["DATA_DIR"]):
    raise Exception("Cannot find the dataset at %s" % config["DATA_DIR"])
if os.system("module list") == 0:
    # then we're on the cluster
    ON_CLUSTER = True
    # need ffmpeg and our conda environment
    shell.prefix(". /share/apps/anaconda3/5.3.1/etc/profile.d/conda.sh; conda activate metamers; "
                 "module load ffmpeg/intel/3.2.2; ")
else:
    ON_CLUSTER = False

MODELS = ['RGC', 'V1']
IMAGES = ['nuts', 'nuts_symmetric', 'nuts_constant', 'einstein', 'einstein_symmetric',
          'einstein_constant']
METAMER_TEMPLATE_PATH = op.join('metamers', '{model_name}', '{image_name}',
                                'scaling-{scaling}', 'seed-{seed}_lr-{learning_rate}_e0-{min_ecc}_'
                                'em-{max_ecc}_iter-{max_iter}_thresh-{loss_thresh}_metamer.png')
SEED_IMAGE_TEMPLATE_PATH = op.join('seed_images', '{image_name}.pgm')

def initial_metamer_inputs(wildcards):
    path_template = op.join(config["DATA_DIR"], METAMER_TEMPLATE_PATH.replace('_metamer.png',
                                                                              '.pt'))
    # return [path_template.format(model_name=m, image_name=i, scaling=s, seed=0, learning_rate=lr,
    #                              min_ecc=.5, max_ecc=15, max_iter=20000, loss_thresh=1e-6) for
    #         m in MODELS for i in IMAGES for s in [.1, .2, .3, .4, .5, .6, .7, .8, .9] for lr in
    #         [.1, 1, 10]]
    metamers = [path_template.format(model_name='V1', image_name=i, scaling=s, seed=0,
                                     learning_rate=lr,min_ecc=.5, max_iter=5000, loss_thresh=1e-6,
                                     # want different max eccentricity
                                     # based on whether we've padded the
                                     # image (and thus doubled its
                                     # width) or not
                                     max_ecc={True: 30, False: 15}['_' in i])
                for i in IMAGES for s in [.4, .5, .6] for lr in [1, 10]]
    metamers.extend([path_template.format(model_name='RGC', image_name=i, scaling=s, seed=0,
                                     learning_rate=lr,min_ecc=.5, max_iter=5000, loss_thresh=1e-6,
                                     # want different max eccentricity
                                     # based on whether we've padded the
                                     # image (and thus doubled its
                                     # width) or not
                                     max_ecc={True: 30, False: 15}['_' in i])
                for i in IMAGES for s in [.2, .3, .4] for lr in [1, 10]])
    return metamers


rule initial_metamers:
    input:
        initial_metamer_inputs,


rule pad_image:
    input:
        op.join(config["DATA_DIR"], 'seed_images', '{image_name}.{ext}')
    output:
        op.join(config["DATA_DIR"], 'seed_images', '{image_name}_{pad_mode}.{ext}')
    log:
        op.join(config["DATA_DIR"], 'logs', 'seed_images', '{image_name}_{pad_mode}-{ext}-%j.log')
    benchmark:
        op.join(config["DATA_DIR"], 'logs', 'seed_images', '{image_name}_{pad_mode}-{ext}_benchmark.txt')
    run:
        import foveated_metamers as met
        met.stimuli.pad_image(input[0], wildcards.pad_mode, output[0])


rule create_metamers:
    input:
        op.join(config["DATA_DIR"], SEED_IMAGE_TEMPLATE_PATH)
    output:
        op.join(config["DATA_DIR"], METAMER_TEMPLATE_PATH.replace('_metamer.png', '.pt')),
        op.join(config["DATA_DIR"], METAMER_TEMPLATE_PATH.replace('metamer.png', 'synthesis.mp4')),
        op.join(config["DATA_DIR"], METAMER_TEMPLATE_PATH)
    log:
        op.join(config["DATA_DIR"], 'logs', 'metamers', '{model_name}', '{image_name}',
                'scaling-{scaling}', 'seed-{seed}_lr-{learning_rate}_e0-{min_ecc}_em-{max_ecc}_'
                'iter-{max_iter}_thresh-{loss_thresh}-%j.log')
    benchmark:
        op.join(config["DATA_DIR"], 'logs', 'metamers', '{model_name}', '{image_name}',
                'scaling-{scaling}', 'seed-{seed}_lr-{learning_rate}_e0-{min_ecc}_em-{max_ecc}_'
                'iter-{max_iter}_thresh-{loss_thresh}_benchmark.txt')
    run:
        import foveated_metamers as met
        if ON_CLUSTER:
            log_file = None
        else:
            log_file = log[0]
        met.create_metamers.main(wildcards.model_name, float(wildcards.scaling), input[0],
                                 int(wildcards.seed), float(wildcards.min_ecc),
                                 float(wildcards.max_ecc), float(wildcards.learning_rate),
                                 int(wildcards.max_iter), float(wildcards.loss_thresh), log_file,
                                 output[0])


# need to come up with a clever way to do this: either delete the ones
# we don't want or make this a function that only takes the ones we want
# or maybe grabs one each for max_iter, loss_thresh, learning_rate.
# Also need to think about how to handle max_ecc; it will be different
# if the images we use as inputs are different sizes.
def get_metamers_for_expt(wildcards):
    ims = ['nuts', 'einstein']
    base_path = op.join(config["DATA_DIR"], METAMER_TEMPLATE_PATH)
    seed_im_path = op.join(config['DATA_DIR'], SEED_IMAGE_TEMPLATE_PATH)
    images = [seed_im_path.format(image_name=i) for i in ims]
    return images+[base_path.format(scaling=s, image_name=i, max_iter=1000, loss_thresh=1e-4,
                                    learning_rate=10, **wildcards) for i in ims
                   for s in [.4, .5, .6]]

rule collect_metamers:
    input:
        get_metamers_for_expt,
    output:
        # we collect across image_name and scaling, and don't care about
        # learning_rate, max_iter, loss_thresh
        op.join(config["DATA_DIR"], 'stimuli', '{model_name}', 'seed-{seed}_e0-{min_ecc}_em-'
                '{max_ecc}_stimuli.npy'),
        op.join(config["DATA_DIR"], 'stimuli', '{model_name}', 'seed-{seed}_e0-{min_ecc}_em-'
                '{max_ecc}_stimuli_description.csv'),
    log:
        op.join(config["DATA_DIR"], 'logs', 'stimuli', '{model_name}', 'seed-{seed}_e0-{min_ecc}_'
                'em-{max_ecc}_stimuli-%j.log'),
    benchmark:
        op.join(config["DATA_DIR"], 'logs', 'stimuli', '{model_name}', 'seed-{seed}_e0-{min_ecc}_'
                'em-{max_ecc}_stimuli_benchmark.txt'),
    run:
        import foveated_metamers as met
        met.stimuli.collect_images(input, output[0])
        template_paths = [op.join(config["DATA_DIR"], p) for p in [METAMER_TEMPLATE_PATH,
                                                                   SEED_IMAGE_TEMPLATE_PATH]]
        met.stimuli.create_metamer_df(input, template_paths, output[1])
