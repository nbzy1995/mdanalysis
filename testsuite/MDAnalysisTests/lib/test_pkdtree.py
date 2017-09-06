# -*- Mode: python; tab-width: 4; indent-tabs-mode:nil; coding:utf-8 -*-
# vim: tabstop=4 expandtab shiftwidth=4 softtabstop=4 fileencoding=utf-8
#
# MDAnalysis --- http://www.mdanalysis.org
# Copyright (c) 2006-2017 The MDAnalysis Development Team and contributors
# (see the file AUTHORS for the full list of names)
#
# Released under the GNU Public Licence, v2 or any higher version
#
# Please cite your use of MDAnalysis in published work:
#
# R. J. Gowers, M. Linke, J. Barnoud, T. J. E. Reddy, M. N. Melo, S. L. Seyler,
# D. L. Dotson, J. Domanski, S. Buchoux, I. M. Kenney, and O. Beckstein.
# MDAnalysis: A Python package for the rapid analysis of molecular dynamics
# simulations. In S. Benthall and S. Rostrup editors, Proceedings of the 15th
# Python in Science Conference, pages 102-109, Austin, TX, 2016. SciPy.
#
# N. Michaud-Agrawal, E. J. Denning, T. B. Woolf, and O. Beckstein.
# MDAnalysis: A Toolkit for the Analysis of Molecular Dynamics Simulations.
# J. Comput. Chem. 32 (2011), 2319--2327, doi:10.1002/jcc.21787
#

from __future__ import print_function, absolute_import
from six.moves import zip

import pytest
import numpy as np
from numpy.testing import assert_equal

from MDAnalysis.lib.pkdtree import PeriodicKDTree


@pytest.fixture
def ptree():
    b = np.array([10, 10, 10, 90, 90, 90], dtype=np.float32)
    coords = np.array([[2, 2, 2],
                       [5, 5, 5],
                       [1.1, 1.1, 1.1],
                       [11, -11, 11],  # wrapped to [1, 9, 1]
                       [21, 21, 3]],  # wrapped to [1, 1, 3]
                      dtype=np.float32)
    t = PeriodicKDTree(b)
    t.set_coords(coords)
    return {'coords': coords, 'tree': t, 'box': b, 'radius': 1.5}

def test_set_coords(ptree):
    with pytest.raises(ValueError) as excinfo:
        xy = np.array([[2, 2], [5, 5], [1.1, 1.1]], dtype=np.float32)
        tree = PeriodicKDTree(ptree['box'])
        tree.set_coords(xy)
    assert_equal(str(excinfo.value),
                 'coords must be a sequence of 3 dimensional coordinates')


queries = ([5, 5, 5],  # case box center
           [1, 5, 5],  # box face
           [5, -1, 5],  # box face
           [1, 1, 5],  # box edge
           [5, -1, 11],  # box edge
           [1, 1, 1],  # box vertex
           [1, -1, 11],  # box vertex
           [21, -31, 1]  # box vertex
           )
centers = (([5, 5, 5], ),
           ([1, 5, 5], [11, 5, 5]),  # centers for first case box face
           ([5, 9, 5], [5, -1, 5]),
           ([1, 1, 5], [11, 1, 5], [1, 11, 5], [11, 11, 5]),
           ([5, 9, 1], [5, -1, 1], [5, 9, 11], [5, -1, 11]),
           ([1, 1, 1], [11, 1, 1], [1, 11, 1], [1, 1, 11],
            [1, 11, 11], [11, 11, 1], [11, 1, 11], [11, 11, 11]),
           ([1, 9, 1], [11, 9, 1], [1, -1, 1], [1, 9, 11],
            [1, -1, 11], [11, -1, 1], [11, 9, 11], [11, -1, 11]),
           ([1, 9, 1], [11, 9, 1], [1, -1, 1], [1, 9, 11],
            [1, -1, 11], [11, -1, 1], [11, 9, 11], [11, -1, 11])
           )


@pytest.mark.parametrize('q, cs', zip(queries, centers))
def test_find_centers(ptree, q, cs):
    q = np.array(q, dtype=np.float32)
    cs = [np.array(c, dtype=np.float32) for c in cs]
    assert_equal(ptree['tree'].find_centers(q, ptree['radius']), cs)


queries = ([5, 5, 5],  # case box center
           [-8.5, 11.5, 2.2],  # wrapped to [1.5, 1.5, 2.2]
           [0, 100, 0.7],  # box face
           [1, 1, 5],  # box edge
           [1, 1, 1],  # box vertex
           [-19, 42, 2],  # box vertex
           [21, -31, 1]  # box vertex
           )
neighbors = (([5, 5, 5], ),
             ([2, 2, 2], [1.1, 1.1, 1.1], [21, 21, 3]),
             ([11, -11, 11], ),
             (),
             ([1.1, 1.1, 1.1], ),
             ([2, 2, 2], [1.1, 1.1, 1.1], [21, 21, 3]),
             ([11, -11, 11], )
             )


@pytest.mark.parametrize('q, ns', zip(queries, neighbors))
def test_search(ptree, q, ns):
    ptree['tree'].search(np.array(q, dtype=np.float32), ptree['radius'])
    indices = ptree['tree'].get_indices()
    found_neighbors = list() if indices is None \
        else [ptree['coords'][i] for i in indices]
    ns = [np.array(n, dtype=np.float32) for n in ns]
    assert_equal(found_neighbors, ns)
