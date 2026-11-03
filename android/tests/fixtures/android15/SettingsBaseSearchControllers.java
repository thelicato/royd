/*
 * Copyright (C) 2014 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Pinned upstream combined code/XML controller assembly, used by the contract.
abstract class SettingsBaseSearchControllers {
    public List<AbstractPreferenceController> getPreferenceControllers(Context context) {
        List<AbstractPreferenceController> controllersFromCode = new ArrayList<>();
        try {
            controllersFromCode = createPreferenceControllers(context);
        } catch (Exception e) {
            Log.w(TAG, "Error initializing controller in fragment: " + this + ", e: " + e);
        }

        final List<SearchIndexableResource> res = getXmlResourcesToIndex(context, true);
        if (res == null || res.isEmpty()) {
            return controllersFromCode;
        }
        List<BasePreferenceController> controllersFromXml = new ArrayList<>();
        for (SearchIndexableResource sir : res) {
            controllersFromXml.addAll(PreferenceControllerListHelper
                    .getPreferenceControllersFromXml(context, sir.xmlResId));
        }
        controllersFromXml = PreferenceControllerListHelper.filterControllers(controllersFromXml,
                controllersFromCode);
        final List<AbstractPreferenceController> allControllers = new ArrayList<>();
        if (controllersFromCode != null) {
            allControllers.addAll(controllersFromCode);
        }
        allControllers.addAll(controllersFromXml);
        return allControllers;
    }
}
